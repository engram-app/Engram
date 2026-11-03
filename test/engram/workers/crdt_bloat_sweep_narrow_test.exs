defmodule Engram.Workers.CrdtBloatSweepNarrowTest do
  @moduledoc """
  The sweep reads stored sizes from the narrow `note_index_state` columns (kept
  by the `note_bodies_sizes` trigger and the state-row upsert, filled by the
  `NoteSizes` ledger) instead
  of aggregating the wide `notes` heap. Same gauges, no `notes` read.
  """
  use Engram.DataCase, async: false

  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteSizes
  alias Engram.Notes
  alias Engram.Repo
  alias Engram.Workers.CrdtBloatSweep
  alias Engram.Workers.DataMigrationsRunner

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Narrow", Ecto.UUID.generate())

    notes =
      for i <- 1..3 do
        {:ok, n} =
          Notes.upsert_note(user, vault, %{"path" => "n#{i}.md", "content" => "body #{i}"},
            actor: "api"
          )

        n
      end

    %{notes: notes}
  end

  defp sizes(note) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT b.content_bytes, b.state_bytes, b.state_bytes IS NOT NULL, s.note_live
        FROM note_bodies b JOIN note_index_state s ON s.note_id = b.note_id WHERE b.note_id = $1
        """,
        [Ecto.UUID.dump!(note.id)]
      )

    row
  end

  defp notes_rows_read do
    %{rows: [[n]]} =
      Repo.query!("""
      SELECT coalesce(seq_tup_read + idx_tup_fetch, 0)::bigint
      FROM pg_stat_xact_user_tables WHERE relname = 'notes'
      """)

    n
  end

  test "the trigger keeps the stored sizes of a write and a soft delete", %{notes: [n | _]} do
    %{rows: [[ct]]} =
      Repo.query!("SELECT content_ciphertext FROM notes WHERE id = $1", [Ecto.UUID.dump!(n.id)])

    assert [content, _state, _has, true] = sizes(n)
    assert content == byte_size(ct) - 16

    Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(n.id)])
    assert [_, _, _, false] = sizes(n)
  end

  # Sizes live on the body row, set by its BEFORE trigger, and liveness rides
  # the existing state-row upsert: a save adds no row version. Measured with
  # pg_stat_xact_user_tables on an ordinary edit and a compaction checkpoint.
  # Red on 156c2fd94: its two size triggers updated note_index_state on every
  # body write and every notes version/updated_at change.
  test "a save and a checkpoint write no extra note_index_state row versions", %{
    notes: [n | _]
  } do
    stat = fn ->
      %{rows: rows} =
        Repo.query!("""
        SELECT relname, n_tup_ins + n_tup_upd FROM pg_stat_xact_user_tables
        WHERE relname IN ('notes', 'note_bodies', 'note_index_state')
        """)

      Map.new(rows, fn [t, v] -> {t, v} end)
    end

    id = Ecto.UUID.dump!(n.id)
    before = stat.()

    # A compaction checkpoint: CRDT state only, with the version/updated_at
    # bump an ordinary checkpoint carries.
    Repo.query!(
      "UPDATE notes SET crdt_state_ciphertext = $2, crdt_state_nonce = $3, version = version + 1, updated_at = now() WHERE id = $1",
      [id, :crypto.strong_rand_bytes(80), <<1>> <> :crypto.strong_rand_bytes(12)]
    )

    # An ordinary content save, raw so no app-level stamp writes run.
    Repo.query!(
      "UPDATE notes SET content_ciphertext = $2, content_nonce = $3, version = version + 1, updated_at = now() WHERE id = $1",
      [id, :crypto.strong_rand_bytes(40), <<1>> <> :crypto.strong_rand_bytes(12)]
    )

    after_ = stat.()
    delta = Map.new(after_, fn {t, v} -> {t, v - Map.get(before, t, 0)} end)

    assert delta["notes"] == 2
    assert delta["note_bodies"] == 2
    assert Map.get(delta, "note_index_state", 0) == 0, inspect(delta)
  end

  # The R8 contract stops writing the `notes` body columns, so the sizes must
  # follow a write that lands on `note_bodies` alone. Red before: the size
  # trigger fired on the notes columns only.
  test "a body-only write moves the stored sizes", %{notes: [n | _]} do
    Repo.query!(
      "UPDATE note_bodies SET content_ct = content_ct || '\\x0102030405'::bytea WHERE note_id = $1",
      [Ecto.UUID.dump!(n.id)]
    )

    %{rows: [[body]]} =
      Repo.query!("SELECT octet_length(content_ct) FROM note_bodies WHERE note_id = $1", [
        Ecto.UUID.dump!(n.id)
      ])

    assert [content, _state, _has, true] = sizes(n)
    assert content == body - 13 - Engram.Crypto.Envelope.tag_bytes()
  end

  test "the ledger fills rows the trigger never saw, then the sweep reads no notes", %{
    notes: notes
  } do
    r0 = notes_rows_read()
    old = CrdtBloatSweep.measure_and_emit()
    old_reads = notes_rows_read() - r0

    Repo.query!("ALTER TABLE note_bodies DISABLE TRIGGER note_bodies_sizes")
    Repo.query!("UPDATE note_bodies SET content_bytes = NULL, state_bytes = NULL")
    Repo.query!("ALTER TABLE note_bodies ENABLE TRIGGER note_bodies_sizes")
    Repo.query!("UPDATE note_index_state SET note_live = NULL")

    refute NoteSizes.done?()
    assert {:more, rows: 6} = NoteSizes.run_pass()
    assert :done = NoteSizes.run_pass()
    assert Enum.all?(notes, &(sizes(&1) |> Enum.at(0) |> is_integer()))
    assert :done = DataMigrationsRunner.run(NoteSizes)
    assert NoteSizes.done?()

    {new, queries} = Engram.QueryRecorder.record(&CrdtBloatSweep.measure_and_emit/0)

    # Red before: the aggregate read every notes row (the old path read all
    # 3). Now notes is read only for the ids written since the last sweep, an
    # `updated_at` range; the sizes come from note_bodies.
    assert old_reads >= 3
    notes_reads = Enum.filter(queries, &(&1.sql =~ ~r/FROM notes\b/))
    assert Enum.all?(notes_reads, &(&1.sql =~ "updated_at >= $1")), inspect(notes_reads)
    refute Enum.any?(queries, &(&1.sql =~ "octet_length(n."))

    # The second run also has a save-rate baseline; compare the gauges both report.
    keys = Map.keys(old) -- [:measured_at_unix]
    assert Map.take(new, keys) == Map.take(old, keys)
  end

  test "a note with no state row keeps the ledger open", %{notes: [n | _]} do
    Repo.query!("DELETE FROM note_index_state WHERE note_id = $1", [Ecto.UUID.dump!(n.id)])
    assert {:more, _} = NoteSizes.run_pass()
    refute DataMigrations.done?(NoteSizes.name(), NoteSizes.version())
  end
end
