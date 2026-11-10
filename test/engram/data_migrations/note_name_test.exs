defmodule Engram.DataMigrations.NoteNameTest do
  # The `NoteName` ledger (O(1) folder rename plan, S2 migrate-data): fills the
  # name columns a previous release left NULL or stale, in one paced chain of
  # bounded hops (`BackfillNoteNames`), and closes on one clean walk. Red
  # before S2: neither module existed.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.RlsCase

  alias Engram.Attachments
  alias Engram.Crypto
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteName
  alias Engram.Folders.Folder
  alias Engram.Notes
  alias Engram.Notes.Name
  alias Engram.Repo
  alias Engram.Workers.BackfillNoteNames

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp note!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  defp attachment!(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{path: path, content: <<137, 80, 78, 71, 1>>})

    att
  end

  # What release D (N-1) leaves: no name at all.
  defp n_minus_1_insert! do
    for t <- ["notes", "attachments"] do
      Repo.query!(
        "UPDATE #{t} SET name_ciphertext = NULL, name_nonce = NULL, name_hmac = NULL, " <>
          "name_ci_hmac = NULL, name_stamp = NULL"
      )
    end

    Repo.query!("UPDATE folders SET name_ci_hmac = NULL, name_stamp = NULL")
  end

  defp name_of(user, table, id) do
    {:ok, dek} = Crypto.get_dek(user)

    case Repo.query!(
           "SELECT name_ciphertext, name_nonce, name_stamp, path_nonce FROM #{table} WHERE id = $1",
           [Ecto.UUID.dump!(id)]
         ) do
      %{rows: [[nil, _, _, _]]} ->
        nil

      %{rows: [[ct, nonce, stamp, path_nonce]]} ->
        if stamp == Name.stamp(path_nonce) do
          {:ok, name} = Name.decrypt(String.to_existing_atom(table), dek, id, ct, nonce)
          name
        else
          :stale
        end
    end
  end

  defp folder_ci(id) do
    %{rows: [[ci, stamp, nonce]]} =
      Repo.query!("SELECT name_ci_hmac, name_stamp, name_nonce FROM folders WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    if stamp == Name.stamp(nonce), do: ci, else: :stale
  end

  # Hops until the chain ends; returns how it ended and how many hops it took.
  defp run_chain(args \\ %{}, opts \\ [], hops \\ 1) do
    case BackfillNoteNames.hop(args, Keyword.put_new(opts, :pause_ms, 0)) do
      {:next, args} when hops < 100 -> run_chain(args, opts, hops + 1)
      other -> {other, hops}
    end
  end

  test "fills the names a previous release left NULL, then closes", %{user: u, vault: v} do
    root = note!(u, v, "Root.md")
    deep = note!(u, v, "A/B/Deep.md")
    att = attachment!(u, v, "A/img.png")
    n_minus_1_insert!()

    refute NoteName.enabled?() == false
    assert {:more, _} = NoteName.run_pass()
    assert [%{args: args}] = all_enqueued(worker: BackfillNoteNames)
    refute DataMigrations.done?(NoteName.name(), NoteName.version())

    # The walk that fixed rows starts a second walk, which is clean: done.
    assert {:done, 2} = run_chain(args)

    assert name_of(u, "notes", root.id) == "Root.md"
    assert name_of(u, "notes", deep.id) == "Deep.md"
    assert name_of(u, "attachments", att.id) == "img.png"

    {:ok, fk} = Crypto.dek_filter_key(u)

    for {path, %{id: id}} <- Engram.FolderRows.tree(u) do
      assert folder_ci(id) == Folder.name_ci_hmac(fk, path |> String.split("/") |> List.last())
    end

    assert DataMigrations.done?(NoteName.name(), NoteName.version())
  end

  test "heals a name a previous release's rename left stale", %{user: u, vault: v} do
    note = note!(u, v, "A/Old.md")

    %{rows: [old]} =
      Repo.query!(
        "SELECT name_ciphertext, name_nonce, name_hmac, name_ci_hmac, name_stamp FROM notes WHERE id = $1",
        [Ecto.UUID.dump!(note.id)]
      )

    {:ok, _} = Notes.rename_note(u, v, "A/Old.md", "A/New.md")

    # Release D renames: new path, old name columns.
    Repo.query!(
      "UPDATE notes SET name_ciphertext = $2, name_nonce = $3, name_hmac = $4, " <>
        "name_ci_hmac = $5, name_stamp = $6 WHERE id = $1",
      [Ecto.UUID.dump!(note.id) | old]
    )

    assert name_of(u, "notes", note.id) == :stale
    assert {:done, _} = run_chain()
    assert name_of(u, "notes", note.id) == "New.md"
  end

  test "a hop is bounded by its row cap and the next resumes at its cursor", %{
    user: u,
    vault: v
  } do
    notes = for i <- 1..5, do: note!(u, v, "N/#{i}.md")
    n_minus_1_insert!()

    opts = [max_rows: 2, batch_size: 1]
    assert {:next, args} = BackfillNoteNames.hop(%{}, opts)
    assert args["from"]
    assert Enum.count(notes, &(name_of(u, "notes", &1.id) != nil)) == 2

    assert {:next, args} = BackfillNoteNames.hop(args, opts)
    assert Enum.count(notes, &(name_of(u, "notes", &1.id) != nil)) == 4

    assert {:done, _} = run_chain(args, opts)
    assert Enum.all?(notes, &(name_of(u, "notes", &1.id) == Path.basename(&1.path)))
  end

  test "perform paces the chain: the successor is scheduled, not immediate", %{
    user: u,
    vault: v
  } do
    for i <- 1..3, do: note!(u, v, "P/#{i}.md")
    n_minus_1_insert!()
    Engram.ServiceConfig.put_override(:note_name_backfill_max_rows, 1)

    assert :ok = perform_job(BackfillNoteNames, %{})
    assert [job] = all_enqueued(worker: BackfillNoteNames)
    assert job.state == "scheduled"
    assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
  end

  # Review F6(a): one unreadable row must not hold the ledger (and the S3
  # read switch) open forever. Red before: the chain stopped, never done.
  test "a row that never decrypts is parked, and the ledger still closes", %{
    user: u,
    vault: v
  } do
    good = note!(u, v, "G/good.md")
    bad = note!(u, v, "G/bad.md")
    n_minus_1_insert!()

    Repo.query!("UPDATE notes SET path_ciphertext = '\\x0001'::bytea WHERE id = $1", [
      Ecto.UUID.dump!(bad.id)
    ])

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :note_name, :skipped]])
    on_exit(fn -> :telemetry.detach(ref) end)

    # Walk 1 names the good row and parks the bad one; walk 2 is clean.
    assert {:done, 2} = run_chain()

    assert_received {[:engram, :note_name, :skipped], ^ref, %{count: 1},
                     %{reason: :undecryptable, table: :notes}}

    assert name_of(u, "notes", good.id) == "good.md"
    assert name_of(u, "notes", bad.id) == nil

    %{rows: [[stamp, nonce]]} =
      Repo.query!("SELECT name_stamp, path_nonce FROM notes WHERE id = $1", [
        Ecto.UUID.dump!(bad.id)
      ])

    assert stamp == Engram.Crypto.NameKeys.unreadable(Name.stamp(nonce))
    assert DataMigrations.done?(NoteName.name(), NoteName.version())
  end

  test "a user mid DEK rotation is left, never parked, and holds the ledger open", %{
    user: u,
    vault: v
  } do
    note = note!(u, v, "L/l.md")
    n_minus_1_insert!()

    Repo.query!("UPDATE users SET dek_rotation_locked_at = now() WHERE id = $1", [
      Ecto.UUID.dump!(u.id)
    ])

    assert {:stopped, 1} = run_chain()
    assert name_of(u, "notes", note.id) == nil
    refute DataMigrations.done?(NoteName.name(), NoteName.version())

    Repo.query!("UPDATE users SET dek_rotation_locked_at = NULL WHERE id = $1", [
      Ecto.UUID.dump!(u.id)
    ])

    assert {:done, _} = run_chain()
    assert name_of(u, "notes", note.id) == "l.md"
  end

  # Review N1: only a provably unreadable key parks rows; a key that fails to
  # load for any other reason defers them (left untouched, counted, retried).
  describe "an owner key that does not load" do
    setup %{user: u, vault: v} do
      note = note!(u, v, "K/deferred.md")
      n_minus_1_insert!()

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:engram, :note_name, :deferred],
          [:engram, :note_name, :skipped]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)
      %{note: note}
    end

    defp raw_stamp(id) do
      %{rows: [[stamp]]} =
        Repo.query!("SELECT name_stamp FROM notes WHERE id = $1", [Ecto.UUID.dump!(id)])

      stamp
    end

    test "a stalled load (timeout) defers the rows and holds the ledger open", %{
      user: u,
      note: note
    } do
      Engram.StalledDekLoad.stall!(u.id)

      assert {:stopped, 1} = run_chain()
      assert raw_stamp(note.id) == nil

      assert_received {[:engram, :note_name, :deferred], _ref, %{count: c},
                       %{reason: :dek_load_timeout}}
                      when c >= 1

      refute_received {[:engram, :note_name, :skipped], _, _, _}
      refute DataMigrations.done?(NoteName.name(), NoteName.version())
    end

    # A user stuck on `:later` keeps the ledger open; what bounds the cost is
    # one full walk a day (`WalkMemo`, S1's rule), not one per hourly pass.
    test "after a walk that fixed nothing, no new walk starts for a day", %{user: u} do
      Engram.StalledDekLoad.stall!(u.id)
      assert {:stopped, 1} = run_chain()

      assert {:more, _} = NoteName.run_pass()
      assert [] = all_enqueued(worker: BackfillNoteNames)

      Repo.query!(
        "UPDATE maintenance_cursors SET cursor = jsonb_set(cursor, '{at}', to_jsonb($1::text)) " <>
          "WHERE name = 'note_name:last_walk'",
        [DateTime.utc_now() |> DateTime.add(-25 * 3600) |> DateTime.to_iso8601()]
      )

      assert {:more, _} = NoteName.run_pass()
      assert [_] = all_enqueued(worker: BackfillNoteNames)
    end

    # Red before N1: `:invalid_wrapping` (a master key that does not open
    # the wrap) parked the rows forever.
    test "a wrap the master key does not open defers, never parks", %{user: u, note: note} do
      %{rows: [[blob]]} =
        Repo.query!("SELECT encrypted_dek FROM users WHERE id = $1", [Ecto.UUID.dump!(u.id)])

      <<head::binary-size(14), byte, rest::binary>> = blob
      bad = head <> <<Bitwise.bxor(byte, 1)>> <> rest

      Repo.query!("UPDATE users SET encrypted_dek = $2 WHERE id = $1", [
        Ecto.UUID.dump!(u.id),
        bad
      ])

      Engram.Crypto.DekCache.invalidate(u.id)

      assert {:stopped, 1} = run_chain()
      assert raw_stamp(note.id) == nil

      assert_received {[:engram, :note_name, :deferred], _ref, %{count: c},
                       %{reason: :invalid_wrapping}}
                      when c >= 1

      refute_received {[:engram, :note_name, :skipped], _, _, _}
      refute DataMigrations.done?(NoteName.name(), NoteName.version())
    end
  end

  # Review F6(b): no walk starts, and the ledger never closes, while a node
  # that does not write names is in the cluster.
  test "an older node in the cluster blocks the walk and the close", %{user: u, vault: v} do
    note = note!(u, v, "F/f.md")
    n_minus_1_insert!()

    behind = [
      peers: fn -> [:"old@10.0.0.9"] end,
      multicall: fn _peers -> [{:error, {:exception, :undef, []}}] end
    ]

    assert :stopped = BackfillNoteNames.hop(%{}, fleet: behind, pause_ms: 0)
    assert name_of(u, "notes", note.id) == nil
    refute DataMigrations.done?(NoteName.name(), NoteName.version())

    assert {:done, _} = run_chain()
  end

  # Review N3: a single-node self-host (no ENGRAM_NODE_ROLE, no
  # DNS_CLUSTER_QUERY, no peers) must pass the gate, or self-hosters would
  # never get the backfill. A node that DECLARES a split fleet but sees no
  # peer waits (blocked, never wrongly closed).
  test "the fleet gate passes on a lone unclustered node and waits on a lone split-fleet node" do
    alone = [role: nil, query: nil, peers: fn -> [] end]
    assert NoteName.fleet_ready?(alone)

    split = [role: :worker, query: nil, peers: fn -> [] end]
    refute NoteName.fleet_ready?(split)
  end

  # Prod's shape: 3 BEAM nodes (web 2, worker 1), found through
  # DNS_CLUSTER_QUERY. From the worker, both web peers must be connected (every
  # discovered A record covered) and answer `Name.writer_level/0`: all on a
  # name-writing build passes; one older build (no such function), one
  # unreachable peer, or a discovered peer not connected blocks.
  test "the fleet gate on prod's 3-node topology" do
    webs = [:"engram@10.0.1.1", :"engram@10.0.1.2"]

    fleet = fn peers, results ->
      [
        role: :worker,
        query: "engram.internal",
        resolver: fn _ -> ["10.0.1.1", "10.0.1.2", "10.0.1.3"] end,
        self_ip: "10.0.1.3",
        peers: fn -> peers end,
        multicall: fn _ -> results end
      ]
    end

    assert NoteName.fleet_ready?(fleet.(webs, [{:ok, 1}, {:ok, 1}]))
    refute NoteName.fleet_ready?(fleet.(webs, [{:ok, 1}, {:error, {:exception, :undef, []}}]))
    refute NoteName.fleet_ready?(fleet.(webs, [{:ok, 1}, {:error, {:erpc, :timeout}}]))
    refute NoteName.fleet_ready?(fleet.([hd(webs)], [{:ok, 1}]))
  end

  test "trashed notes and rename tombstones are named too; markers are not", %{
    user: u,
    vault: v
  } do
    trashed = note!(u, v, "T/trashed.md")
    note!(u, v, "T/old.md")
    {:ok, _} = Notes.rename_note(u, v, "T/old.md", "T/new.md")
    :deleted = Notes.delete_note_reporting(u, v, "T/trashed.md")
    {:ok, marker} = Notes.create_folder_marker(u, v, "Empty/Deep")
    n_minus_1_insert!()

    assert {:done, _} = run_chain()

    assert name_of(u, "notes", trashed.id) == "trashed.md"

    %{rows: tombs} =
      Repo.query!(
        "SELECT id FROM notes WHERE user_id = $1 AND deleted_at IS NOT NULL AND kind = 'note' AND id <> $2",
        [Ecto.UUID.dump!(u.id), Ecto.UUID.dump!(trashed.id)]
      )

    assert [[tomb]] = tombs
    assert name_of(u, "notes", Ecto.UUID.load!(tomb)) == "old.md"

    # The marker stays unnamed and did not hold the ledger open.
    assert %{rows: [[nil, nil]]} =
             Repo.query!("SELECT name_ciphertext, name_stamp FROM notes WHERE id = $1", [
               Ecto.UUID.dump!(marker.id)
             ])
  end

  # A concurrent rename wins: a fix lands only while the row still holds the
  # nonce it was derived from.
  test "the write is a compare-and-set on the source nonce", %{user: u, vault: v} do
    note = note!(u, v, "C/cas.md")
    n_minus_1_insert!()
    {:ok, dek} = Crypto.get_dek(u)
    {:ok, fk} = Crypto.dek_filter_key(u)
    stale_src = :crypto.strong_rand_bytes(12)

    fix = %{
      id: note.id,
      src: stale_src,
      cols: Name.keys(:notes, dek, fk, note.id, "C/cas.md", stale_src)
    }

    assert {:ok, 0} =
             Repo.with_tenant(u.id, fn -> BackfillNoteNames.write(:notes, Repo, [fix]) end)

    assert name_of(u, "notes", note.id) == nil

    %{rows: [[src]]} =
      Repo.query!("SELECT path_nonce FROM notes WHERE id = $1", [Ecto.UUID.dump!(note.id)])

    fix = %{fix | src: src, cols: Name.keys(:notes, dek, fk, note.id, "C/cas.md", src)}

    assert {:ok, 1} =
             Repo.with_tenant(u.id, fn -> BackfillNoteNames.write(:notes, Repo, [fix]) end)

    assert name_of(u, "notes", note.id) == "cas.md"
  end

  test "the kill switch stops the chain and the runner pass", %{user: u, vault: v} do
    note!(u, v, "K/k.md")
    n_minus_1_insert!()
    Engram.ServiceConfig.put_override(:note_name_backfill, false)

    refute NoteName.enabled?()
    assert :ok = perform_job(BackfillNoteNames, %{})
    assert [] = all_enqueued(worker: BackfillNoteNames)
  end

  test "run_pass does not start a second chain while one is in flight", %{user: u, vault: v} do
    note!(u, v, "C/c.md")
    n_minus_1_insert!()
    assert {:more, _} = NoteName.run_pass()
    assert {:more, _} = NoteName.run_pass()
    assert [_] = all_enqueued(worker: BackfillNoteNames)
  end

  describe "RLS" do
    test "control: in another tenant's context the heal reads and writes nothing", %{
      user: u,
      vault: v
    } do
      note = note!(u, v, "R/r.md")
      other = insert(:user)
      n_minus_1_insert!()

      assert {0, false} =
               as_prod_role_committing(fn ->
                 BackfillNoteNames.heal_window(:notes, [note.id], %{repo: Repo, user_id: other.id})
               end)

      assert name_of(u, "notes", note.id) == nil
    end

    test "in the owner's tenant the heal writes the row", %{user: u, vault: v} do
      note = note!(u, v, "R/r.md")
      n_minus_1_insert!()

      assert {1, false} =
               as_prod_role_committing(fn ->
                 BackfillNoteNames.heal_window(:notes, [note.id], %{repo: Repo, user_id: u.id})
               end)

      assert name_of(u, "notes", note.id) == "r.md"
    end
  end
end
