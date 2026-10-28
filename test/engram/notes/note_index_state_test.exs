defmodule Engram.Notes.NoteIndexStateTest do
  # The notes_sync_index_state trigger keeps note_index_state in step with
  # every write of an embed bookkeeping column, and the NoteIndexState data
  # migration fills rows written before it.
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.DataMigrations.NoteIndexState, as: Backfill
  alias Engram.Notes
  alias Engram.Notes.{Note, NoteIndexState}
  alias Engram.QueryRecorder
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp write!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  defp state(id), do: Repo.get(NoteIndexState, id, skip_tenant_check: true)
  defp note(id), do: Repo.get!(Note, id, skip_tenant_check: true)

  defp xmin(id) do
    %{rows: [[x]]} =
      Repo.query!("SELECT xmin::text FROM note_index_state WHERE note_id = $1", [
        Ecto.UUID.dump!(id)
      ])

    x
  end

  defp mirrors?(state, note),
    do: Map.take(state, NoteIndexState.mirrored()) == Map.take(note, NoteIndexState.mirrored())

  defp stamp!(id, set),
    do: Repo.update_all(from(n in Note, where: n.id == ^id), [set: set], skip_tenant_check: true)

  test "a note insert writes its state row", %{user: u, vault: v} do
    n = write!(u, v, "A.md", "# A\n\nbody")
    assert %NoteIndexState{user_id: user_id} = s = state(n.id)
    assert user_id == u.id
    assert mirrors?(s, note(n.id))
  end

  test "every embed stamp reaches the state row", %{user: u, vault: v} do
    n = write!(u, v, "A.md", "# A\n\nbody")
    at = ~U[2026-10-24 12:00:00.000000Z]

    stamp!(n.id,
      embed_hash: n.content_hash,
      dense_indexed_hash: n.content_hash,
      chunker_version: 5,
      keyword_version: 4,
      key_alias_version: 2,
      embed_model: "voyage-4-large",
      payload_hash: <<1, 2, 3>>,
      index_tier: "floor",
      chunk_count: 7,
      rebuild_paid_at: at,
      embed_retry_after: at,
      embed_budget_parked: true,
      embed_budget_parked_at: at,
      embed_budget_need: 1_234,
      embed_budget_next: 56,
      embed_started_at: at,
      embed_started_by: "node@x",
      embed_started_hash: n.content_hash,
      embed_crashes: 2
    )

    s = state(n.id)
    assert s.chunker_version == 5 and s.embed_budget_need == 1_234 and s.index_tier == "floor"
    assert mirrors?(s, note(n.id))

    # And a NULL-clear (DEK rotation, cluster diff, payload drift).
    stamp!(n.id, keyword_version: nil, payload_hash: nil)
    assert %{keyword_version: nil, payload_hash: nil} = state(n.id)
  end

  test "a write that lists no mirrored column leaves the state row alone", %{user: u, vault: v} do
    n = write!(u, v, "A.md", "# A\n\nbody")
    before = xmin(n.id)

    stamp!(n.id, mtime: 42.0)
    assert xmin(n.id) == before

    # Listed but unchanged: the upsert skips an identical row.
    stamp!(n.id, embed_hash: note(n.id).embed_hash)
    assert xmin(n.id) == before
  end

  test "a folder marker gets no state row", %{user: u, vault: v} do
    {:ok, folder} = Notes.create_folder_marker(u, v, "Dir")
    assert state(folder.id) == nil
  end

  test "the row goes with its note", %{user: u, vault: v} do
    n = write!(u, v, "A.md", "# A\n\nbody")
    Repo.delete_all(from(x in Note, where: x.id == ^n.id), skip_tenant_check: true)
    assert state(n.id) == nil
  end

  describe "NoteIndexState backfill" do
    test "fills rows written before the trigger, then reports done", %{user: u, vault: v} do
      a = write!(u, v, "A.md", "# A\n\nbody")
      b = write!(u, v, "B.md", "# B\n\nbody")
      stamp!(a.id, chunker_version: 3, embed_budget_need: 9)
      Repo.query!("DELETE FROM note_index_state")

      assert {:more, rows: 2} = Backfill.run_pass()
      assert mirrors?(state(a.id), note(a.id))
      assert state(a.id).chunker_version == 3
      assert mirrors?(state(b.id), note(b.id))
      assert :done = Backfill.run_pass()
    end

    test "never replaces a row the trigger wrote", %{user: u, vault: v} do
      a = write!(u, v, "A.md", "# A\n\nbody")
      Repo.query!("UPDATE note_index_state SET keyword_version = 99")

      assert :done = Backfill.run_pass()
      assert state(a.id).keyword_version == 99
    end

    # #2276: the pass bounds rows READ per statement, not rows returned. One
    # drifted note at the END of the id order, behind clean ones: the old
    # "next N matching notes" query walked every clean note to reach it, and
    # the "anything left?" EXISTS walked the table again. Every statement that
    # reads `notes` must be a pure keyset window or confined to one window's
    # ids.
    test "a missing row at the end of the table, every statement one window", %{
      user: u,
      vault: v
    } do
      notes = for i <- 1..9, do: write!(u, v, "W#{i}.md", "# W\n\nbody #{i}")
      last = Enum.max_by(notes, & &1.id)
      Repo.query!("DELETE FROM note_index_state WHERE note_id = $1", [Ecto.UUID.dump!(last.id)])

      {_, queries} =
        QueryRecorder.record(fn ->
          assert {:more, rows: 1} = Backfill.run_pass(batch: 2)
          assert :done = Backfill.run_pass(batch: 2)
        end)

      assert mirrors?(state(last.id), note(last.id))
      assert Enum.any?(queries, &(&1.sql =~ "notes"))
      assert QueryRecorder.unwindowed(queries, "notes", 2) == []
    end

    test "keyset-pages across batches", %{user: u, vault: v} do
      for i <- 1..3, do: write!(u, v, "N#{i}.md", "# N\n\nbody #{i}")
      Repo.query!("DELETE FROM note_index_state")

      assert {:more, rows: 3} = Backfill.run_pass(batch: 2)
      assert :done = Backfill.run_pass(batch: 2)
    end
  end

  describe "NoteIndexState pass on prod-size data" do
    # Prod (70k notes, 421k chunks) failed the pass with a 15 s DBConnection
    # timeout: the done check and the recount each scanned ALL notes with a
    # correlated chunk count in one statement. Every statement must now be
    # bounded to an id window, however sparse the drift.
    setup %{user: u, vault: v} do
      seed = write!(u, v, "seed.md", "# S\n\nbody")

      Repo.query!(
        """
        INSERT INTO notes
        SELECT (r).* FROM (
          SELECT jsonb_populate_record(null::notes,
                   to_jsonb(n) || jsonb_build_object('id', gen_random_uuid(),
                                                     'path', 'gen/' || g || '.md',
                                                     'path_hmac', '\\\\x' || md5(g::text))) AS r
          FROM notes n, generate_series(1, 2999) g WHERE n.id = $1) x
        """,
        [Ecto.UUID.dump!(seed.id)]
      )

      %{rows: [[total]]} = Repo.query!("SELECT count(*) FROM note_index_state")
      assert total == 3000
      :ok
    end

    # Scans of `chunks` so far in this transaction (seq + index, each
    # correlated-subquery probe counts one).
    defp chunk_probes do
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT coalesce(sum(seq_scan + idx_scan), 0)::bigint " <>
            "FROM pg_stat_xact_user_tables WHERE relname = 'chunks'"
        )

      n
    end

    # `chunks` probes issued by each drift-scan statement of a pass.
    defp probes_per_statement(fun) do
      test = self()
      id = {__MODULE__, make_ref()}
      Process.put(:last_probes, chunk_probes())

      :telemetry.attach(
        id,
        [:engram, :repo, :query],
        fn _, _, %{query: q}, _ ->
          if q =~ "FROM chunks c WHERE" do
            now = chunk_probes()
            send(test, {:probes, now - Process.get(:last_probes, 0)})
            Process.put(:last_probes, now)
          end
        end,
        nil
      )

      try do
        {fun.(), drain([])}
      after
        :telemetry.detach(id)
      end
    end

    defp drain(acc) do
      receive do
        {:probes, n} -> drain([n | acc])
      after
        0 -> acc
      end
    end

    test "a clean ledger probes chunks once per note, a bounded window per statement" do
      {result, probes} = probes_per_statement(fn -> Backfill.run_pass(batch: 500) end)

      assert result == :done
      # Old code: one statement probed all 3000 notes, and the done check
      # probed them all again. Now: 6 full windows of 500, 3000 total (the
      # empty window that ends the walk runs no drift scan).
      assert length(probes) == 6
      assert Enum.max(probes) <= 500 + 25
      assert Enum.sum(probes) <= 3000 + 100
    end

    test "a note whose state row vanishes mid-pass keeps the pass open", %{user: u} do
      # The first note in id order: its window's fill runs first, so the
      # delete below lands after that fill and before that window's scan.
      victim =
        Repo.one!(from(n in Note, select: n.id, order_by: n.id, limit: 1),
          skip_tenant_check: true
        )
      test = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach(
        id,
        [:engram, :repo, :query],
        fn _, _, %{query: q}, _ ->
          # After the first window's fill, before its drift scan.
          if q =~ "note_index_state_sync" and Process.get(:deleted) != true do
            Process.put(:deleted, true)

            Repo.query!("DELETE FROM note_index_state WHERE note_id = $1", [
              Ecto.UUID.dump!(victim)
            ])

            send(test, :deleted)
          end
        end,
        nil
      )

      try do
        assert {:more, rows: 1} = Backfill.run_pass()
        assert_received :deleted
      after
        :telemetry.detach(id)
      end

      assert state(victim) == nil
      assert {:more, rows: 1} = Backfill.run_pass()
      assert state(victim)
      assert :done = Backfill.run_pass()
      _ = u
    end

    test "a pass that runs out of time never reports done" do
      assert {:more, _} = Backfill.run_pass(batch: 500, budget_ms: -1)
    end

    test "the walk reaches the last note of a many-window table" do
      Repo.query!(
        "UPDATE note_index_state SET points = 99 WHERE note_id = (SELECT id FROM notes ORDER BY id DESC LIMIT 1)"
      )

      assert {:more, rows: 1} = Backfill.run_pass(batch: 250)
      assert :done = Backfill.run_pass(batch: 250)
    end

    test "sparse drift among thousands is fixed exactly, then the ledger closes", %{user: u} do
      drifted =
        Repo.query!(
          "UPDATE note_index_state SET points = 99 WHERE note_id IN " <>
            "(SELECT note_id FROM note_index_state ORDER BY note_id OFFSET 1500 LIMIT 3) " <>
            "RETURNING note_id"
        ).rows

      assert length(drifted) == 3
      assert {:more, rows: 3} = Backfill.run_pass(batch: 500)
      assert :done = Backfill.run_pass(batch: 500)

      assert Repo.aggregate(from(s in NoteIndexState, where: s.points == 99), :count,
               skip_tenant_check: true
             ) == 0

      _ = u
    end
  end

  describe "RLS" do
    test "control: the dropped role with no tenant sees zero rows", %{user: u, vault: v} do
      write!(u, v, "A.md", "# A\n\nbody")
      assert Repo.aggregate(NoteIndexState, :count, skip_tenant_check: true) > 0

      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.aggregate(NoteIndexState, :count, skip_tenant_check: true)
               end)
    end

    test "a tenant sees only its own rows", %{user: u, vault: v} do
      mine = write!(u, v, "A.md", "# A\n\nbody")
      other = insert(:user)
      {:ok, other} = Engram.Crypto.ensure_user_dek(other)
      write!(other, insert(:vault, user: other), "B.md", "# B\n\nbody")

      assert {:returned, {:ok, [id]}} =
               as_prod_role(fn ->
                 Repo.with_tenant(u.id, fn ->
                   Repo.all(from(s in NoteIndexState, select: s.note_id))
                 end)
               end)

      assert id == mine.id
    end

    test "the trigger writes under the app role inside the tenant", %{user: u, vault: v} do
      n = write!(u, v, "A.md", "# A\n\nbody")

      # Read back under the same role: a trigger write filtered to zero rows
      # by RLS would leave the state row's old value (review L4).
      assert {:returned, {:ok, {{1, nil}, 4}}} =
               as_prod_role(fn ->
                 Repo.with_tenant(u.id, fn ->
                   updated =
                     Repo.update_all(from(x in Note, where: x.id == ^n.id),
                       set: [chunker_version: 4]
                     )

                   {updated,
                    Repo.one(
                      from(s in NoteIndexState,
                        where: s.note_id == ^n.id,
                        select: s.chunker_version
                      )
                    )}
                 end)
               end)
    end
  end
end
