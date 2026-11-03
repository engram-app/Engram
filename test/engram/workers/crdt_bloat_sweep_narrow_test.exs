defmodule Engram.Workers.CrdtBloatSweepNarrowTest do
  @moduledoc """
  The sweep reads stored sizes from the narrow `note_index_state` columns (kept
  by the `notes_sync_sizes` trigger, filled by the `NoteSizes` ledger) instead
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
        "SELECT content_bytes, state_bytes, has_state, note_live FROM note_index_state WHERE note_id = $1",
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

  test "the ledger fills rows the trigger never saw, then the sweep reads no notes", %{
    notes: notes
  } do
    r0 = notes_rows_read()
    old = CrdtBloatSweep.measure_and_emit()
    old_reads = notes_rows_read() - r0

    Repo.query!("""
    UPDATE note_index_state SET content_bytes = NULL, state_bytes = NULL, has_state = NULL,
      note_live = NULL, note_version = NULL, note_updated_at = NULL
    """)

    refute NoteSizes.done?()
    assert {:more, rows: 3} = NoteSizes.run_pass()
    assert :done = NoteSizes.run_pass()
    assert Enum.all?(notes, &(sizes(&1) |> Enum.at(0) |> is_integer()))
    assert :done = DataMigrationsRunner.run(NoteSizes)
    assert NoteSizes.done?()

    before = notes_rows_read()
    new = CrdtBloatSweep.measure_and_emit()

    # Red before this change: the aggregate read every notes row (the old path
    # read all 3). The one row left is the tenancy probe's, not the aggregate's.
    assert old_reads >= 3
    assert notes_rows_read() - before < old_reads
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
