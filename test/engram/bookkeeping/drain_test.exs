defmodule Engram.Bookkeeping.DrainTest do
  # Not async: the drain probes every tenant and the ledger rows are global.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Bookkeeping.Drain
  alias Engram.DataMigrations
  alias Engram.DataMigrations.FolderTable
  alias Engram.Notes
  alias Engram.QueryPlan
  alias Engram.Repo
  alias Engram.Workers.BackfillLinkKeys
  alias Engram.Workers.BookkeepingDrain
  alias Engram.Workers.ReencodeEnvelopes

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Drain", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp write!(user, vault, path) do
    {:ok, n} = Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")
    n
  end

  defp sql!(statement, args \\ []), do: Repo.query!(statement, args)

  defp put_att!(user, vault, path) do
    {:ok, att} =
      Engram.Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes of " <> path)
      })

    att
  end

  defp folder_ref(id) do
    %{rows: [[ref]]} =
      sql!("SELECT folder_ref_id FROM attachments WHERE id = $1", [Ecto.UUID.dump!(id)])

    ref && Ecto.UUID.load!(ref)
  end

  # What a previous-release node writes on a move: the path columns (a fresh
  # nonce), not this release's reference stamp.
  defp old_release_move!(user, att, new_path) do
    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, fk} = Engram.Crypto.dek_filter_key(user)
    aad = Engram.Crypto.aad_for_row(:attachments, :path, att.id)
    {ct, nonce} = Engram.Crypto.Envelope.encrypt(new_path, dek, aad)

    sql!(
      "UPDATE attachments SET path_ciphertext = $2, path_nonce = $3, path_hmac = $4 WHERE id = $1",
      [Ecto.UUID.dump!(att.id), ct, nonce, Engram.Crypto.hmac_field(fk, new_path)]
    )
  end

  defp zero?(counts), do: Enum.all?(Map.values(counts), &(&1 == 0))

  test "clean data: the drain finds and queues nothing", %{user: u, vault: v} do
    write!(u, v, "Folder/clean.md")
    write!(u, v, "root.md")
    assert zero?(Drain.run())
    refute_enqueued(worker: ReencodeEnvelopes)
    refute_enqueued(worker: BackfillLinkKeys)
  end

  # Positive controls: a previous-release writer's rows. Red before the
  # drain: nothing looked for them between the daily re-verifies.
  describe "an old writer's drift" do
    test "a format-0 envelope queues the re-encode once, however many ticks", %{
      user: u,
      vault: v
    } do
      n = write!(u, v, "legacy.md")

      sql!(
        "UPDATE notes SET content_nonce = '\\x000000000000000000000000'::bytea WHERE id = $1",
        [
          Ecto.UUID.dump!(n.id)
        ]
      )

      # Where the probe reads it: nothing copies a raw notes write any more.
      Engram.Fixtures.mirror_body!(n.id)

      assert %{envelope: 1} = Drain.run()
      assert %{envelope: 1} = Drain.run()
      assert_enqueued(worker: ReencodeEnvelopes, args: %{"user_id" => u.id})
      assert [_one] = all_enqueued(worker: ReencodeEnvelopes)
    end

    test "a stale link-key stamp queues the key backfill", %{user: u, vault: v} do
      n = write!(u, v, "stale.md")

      sql!("UPDATE notes SET link_keys_stamp = '\\x00'::bytea WHERE id = $1", [
        Ecto.UUID.dump!(n.id)
      ])

      assert %{link_keys: 1} = Drain.run()
      assert_enqueued(worker: BackfillLinkKeys, args: %{"user_id" => u.id})
    end

    # Red on c0c603cb9: its index read `chunk_count > 0`, which ordinary
    # full-tier notes never set, so a lost write race was never found.
    test "an ordinary indexed note whose stamp was lost queues the payload heal", %{
      user: u,
      vault: v
    } do
      n = write!(u, v, "indexed.md")
      Engram.Fixtures.insert_chunk!(u, n, Ecto.UUID.generate())

      sql!("UPDATE notes SET payload_hash = NULL, chunk_count = NULL WHERE id = $1", [
        Ecto.UUID.dump!(n.id)
      ])

      assert %{payload: 1} = Drain.run()
      assert_enqueued(worker: Engram.Workers.ReconcileNotePayloads, args: %{"user_id" => u.id})
    end

    test "an unstamped state row with no points is a false positive the worker's predicate drops",
         %{user: u, vault: v} do
      n = write!(u, v, "p.md")

      sql!(
        "UPDATE note_index_state SET points = 3, payload_hash = NULL WHERE note_id = $1",
        [Ecto.UUID.dump!(n.id)]
      )

      assert %{payload: 0} = Drain.run()
    end

    test "a note whose folder has no row is healed; a root note is not a candidate", %{
      user: u,
      vault: v
    } do
      n = write!(u, v, "Lost/n.md")
      root = write!(u, v, "root2.md")
      sql!("UPDATE notes SET folder_ref_id = NULL")
      sql!("DELETE FROM folders")

      :ok = DataMigrations.mark_done(FolderTable.name(), FolderTable.version())
      assert %{folder: 1, folder_blocked: 0} = Drain.run()

      %{rows: [[ref]]} =
        sql!("SELECT folder_ref_id FROM notes WHERE id = $1", [Ecto.UUID.dump!(n.id)])

      assert ref != nil

      %{rows: [[root_ref]]} =
        sql!("SELECT folder_ref_id FROM notes WHERE id = $1", [Ecto.UUID.dump!(root.id)])

      assert root_ref == nil
      assert zero?(Drain.run())
    end

    # #2413. The previous release moves an attachment: it rewrites the path
    # (fresh nonce) and leaves the old folder's reference. Red before the
    # stamp: nothing but FolderTable's nightly walk ever looked at attachments.
    # No walk here: the clean row's path is corrupted, so a pass that decrypted
    # it would count it blocked.
    test "an attachment an old writer moved is re-pointed by the drain, no walk", %{
      user: u,
      vault: v
    } do
      att = put_att!(u, v, "Old/x.png")
      clean = put_att!(u, v, "Keep/y.png")
      old_folder = folder_ref(att.id)
      old_release_move!(u, att, "New/x.png")

      sql!("UPDATE attachments SET path_ciphertext = '\\x00'::bytea WHERE id = $1", [
        Ecto.UUID.dump!(clean.id)
      ])

      :ok = DataMigrations.mark_done(FolderTable.name(), FolderTable.version())
      assert folder_ref(att.id) == old_folder
      assert %{folder: 1, folder_blocked: 0} = Drain.run()

      new_ref = folder_ref(att.id)
      assert new_ref != old_folder
      assert Engram.FolderRows.tree(u)["New"].id == new_ref
      # (Its link keys are stale too, the simulated writer skipped them: that
      # is the link-key probe's.)
      assert %{folder: 0} = Drain.run()
    end

    # One unstamped row whose path cannot be decrypted is logged once, then
    # left out of the index until a writer gives it a fresh nonce: it must not
    # re-run its user's FolderTable pass on every tick.
    test "an unreadable unstamped attachment is logged once, then skipped until rewritten", %{
      user: u,
      vault: v
    } do
      att = put_att!(u, v, "Bad/x.png")

      sql!(
        "UPDATE attachments SET folder_ref_stamp = NULL, path_ciphertext = '\\x00'::bytea WHERE id = $1",
        [Ecto.UUID.dump!(att.id)]
      )

      :ok = DataMigrations.mark_done(FolderTable.name(), FolderTable.version())

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{folder: 1, folder_blocked: 1} = Drain.run()
        end)

      assert log =~ "attachment path did not decrypt"
      assert %{folder: 0} = Drain.run()

      # Readers still never trust it: the stamp is not its nonce.
      %{rows: [[false]]} =
        sql!("SELECT folder_ref_stamp = path_nonce FROM attachments WHERE id = $1", [
          Ecto.UUID.dump!(att.id)
        ])

      # A writer's fresh nonce ends the skip: the upload re-points and stamps.
      {:ok, _} =
        Engram.Attachments.upsert_attachment(u, v, %{
          "path" => "Bad/x.png",
          "content_base64" => Base.encode64("new bytes")
        })

      assert %{folder: 0} = Drain.run()

      %{rows: [[true]]} =
        sql!("SELECT folder_ref_stamp = path_nonce FROM attachments WHERE id = $1", [
          Ecto.UUID.dump!(att.id)
        ])
    end

    test "an open FolderTable ledger is left to the hourly runner", %{user: u, vault: v} do
      write!(u, v, "Open/n.md")
      sql!("UPDATE notes SET folder_ref_id = NULL")
      sql!("DELETE FROM folders")
      assert %{folder: 1} = Drain.run()
      %{rows: [[n]]} = sql!("SELECT count(*) FROM notes WHERE folder_ref_id IS NOT NULL")
      assert n == 0
    end
  end

  # Each probe is pinned to its partial index: a predicate that drifts from the
  # index text silently becomes a table scan. Red if either side changes alone.
  describe "every probe is served by its partial index" do
    @indexes %{
      envelope: ~w(note_bodies_envelope_legacy
                   crdt_update_log_envelope_legacy vault_index_states_envelope_legacy
                   vault_index_update_log_envelope_legacy),
      link_keys: ~w(notes_link_keys_stale_index attachments_link_keys_stale_index
                    note_links_link_keys_stale_index),
      payload: ~w(note_index_state_unstamped),
      folder: ~w(notes_unresolved_folder attachments_folder_ref_stale)
    }

    # Realistic statistics, set by this test: many clean live notes, no drift.
    # On an empty table every candidate index costs the same (8.15) and the
    # planner's pick depends on whatever reltuples/relpages an EARLIER test's
    # ANALYZE left behind (ANALYZE writes those in place, so the sandbox
    # rollback does not undo them). CI on #2424 drew notes_user_id_vault_id_
    # path_ci_hmac_index that way once new test files reshuffled partitions.
    setup %{user: u, vault: v} do
      for i <- 1..100, do: write!(u, v, "Clean#{rem(i, 5)}/n#{i}.md")
      :ok
    end

    for {kind, names} <- @indexes do
      test "#{kind}" do
        probes = Drain.probes(unquote(kind))
        assert length(probes) == length(unquote(names))

        for {{table, sql}, name} <- Enum.zip(probes, unquote(names)) do
          plan = QueryPlan.generic_plan(sql, analyze: [table], fresh: true)

          assert plan =~ name, "#{table} probe does not use #{name}:\n#{plan}"
          refute plan =~ "Seq Scan on #{table}", plan
        end
      end
    end
  end

  # The fleet `n` walk's per-user probe (`ReconcileNotePayloads`) reads
  # `note_index_state` through its own partial index, so a done user costs a
  # few index pages, not a walk of its notes. The `coalesce(..., 5) < 6` text
  # is the index predicate's literal: red if either side changes alone.
  test "the n backfill's per-user probe is served by note_index_state_n_behind", %{
    user: u,
    vault: v
  } do
    for i <- 1..100, do: write!(u, v, "Clean#{rem(i, 5)}/n#{i}.md")

    {sql, _params} =
      Repo.to_sql(:all, Engram.Workers.ReconcileNotePayloads.n_behind_probe(u.id))

    assert sql =~ "coalesce("
    plan = QueryPlan.generic_plan(sql, analyze: ["note_index_state"], fresh: true)
    assert plan =~ "note_index_state_n_behind", plan
    refute plan =~ "Seq Scan on note_index_state", plan
  end

  # The folder probe competes with other partial indexes on live notes. With
  # realistic statistics (many resolved live notes, one unresolved) the planner
  # must pick the drift index, not walk live notes. Red on c0c603cb9's test,
  # which dropped every competitor first and so could not tell.
  test "with real statistics the folder probe picks its index over live-note indexes", %{
    user: u,
    vault: v
  } do
    for i <- 1..150, do: write!(u, v, "F#{rem(i, 5)}/n#{i}.md")
    lost = write!(u, v, "Lost/x.md")
    sql!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [Ecto.UUID.dump!(lost.id)])

    [{table, sql} | _] = Drain.probes(:folder)
    plan = QueryPlan.generic_plan(sql, analyze: [table], fresh: true)
    assert plan =~ "notes_unresolved_folder", plan
  end

  # One definition per drift test in practice: the probe's users are exactly
  # the users the repair worker's own selection finds, on a mixed fixture.
  test "each probe finds exactly the users its worker would repair", %{user: u, vault: v} do
    other = insert(:user)
    insert(:user_limit_override, user: other, key: "vaults_cap", value: %{"v" => -1})
    {:ok, other} = Engram.Crypto.ensure_user_dek(other)
    {:ok, ov, _} = Engram.Vaults.register_vault(other, "Clean", Ecto.UUID.generate())
    write!(other, ov, "clean.md")

    legacy = write!(u, v, "legacy.md")
    stale = write!(u, v, "stale.md")
    stamped = write!(u, v, "pay.md")
    Engram.Fixtures.insert_chunk!(u, stamped, Ecto.UUID.generate())

    sql!("UPDATE notes SET content_nonce = '\\x000000000000000000000000'::bytea WHERE id = $1", [
      Ecto.UUID.dump!(legacy.id)
    ])

    Engram.Fixtures.mirror_body!(legacy.id)

    sql!("UPDATE notes SET link_keys_stamp = '\\x00'::bytea WHERE id = $1", [
      Ecto.UUID.dump!(stale.id)
    ])

    sql!("UPDATE notes SET payload_hash = NULL WHERE id = $1", [Ecto.UUID.dump!(stamped.id)])

    users = [u.id, other.id]

    for {kind, worker_selects?} <- [
          envelope: &ReencodeEnvelopes.legacy_rows?/1,
          link_keys: &BackfillLinkKeys.missing_rows?/1,
          payload: &Engram.Workers.ReconcileNotePayloads.unstamped_rows?/1
        ] do
      expected = users |> Enum.filter(worker_selects?) |> Enum.sort()

      assert (Enum.sort(Drain.candidates(kind)) -- [nil]) |> Enum.filter(&(&1 in users)) ==
               expected,
             "#{kind}: probe and worker disagree"
    end
  end

  # The fleet cursor moves past every user a probe returns, so the folder
  # probe must return only the users one tick repairs. Red on 156c2fd94: it
  # paged 100 and repaired 10, so 90 were skipped and stuck users starved them.
  test "the folder probe pages exactly the users one tick repairs" do
    assert Drain.page(:folder) == 10

    for kind <- [:folder, :envelope, :link_keys, :payload],
        {_t, sql} <- Drain.probes(kind),
        do: assert(sql =~ "LIMIT #{Drain.page(kind)}\n")
  end

  test "the cron worker runs a tick and dedups while one is incomplete" do
    assert :ok = perform_job(BookkeepingDrain, %{})
    {:ok, first} = Oban.insert(BookkeepingDrain.new(%{}))
    {:ok, second} = Oban.insert(BookkeepingDrain.new(%{}))
    assert second.conflict? and second.id == first.id
  end

  # The root exclusion rests on this: an empty folder encrypts to the bare tag.
  test "a root note's folder envelope is the 16-byte tag", %{user: u, vault: v} do
    n = write!(u, v, "rootcheck.md")

    %{rows: [[len]]} =
      sql!("SELECT octet_length(folder_ciphertext) FROM notes WHERE id = $1", [
        Ecto.UUID.dump!(n.id)
      ])

    assert len == Engram.Crypto.Envelope.tag_bytes()
  end
end
