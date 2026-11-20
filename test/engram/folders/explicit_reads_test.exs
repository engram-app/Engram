defmodule Engram.Folders.ExplicitReadsTest do
  # S6 step 4, phase 1 (Engram#2523): folder listings read explicit folders
  # from `folders.explicit`, not from the `kind = 'folder'` marker rows, and
  # an id a listing hands out resolves for the id-keyed folder operations.
  # Writers still insert markers in this release (the previous release reads
  # them), so a marker with no explicit row, or the reverse, only exists here
  # by a raw write: the reverse is what the write stop (phase 2) leaves.
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.{DataMigrations, FolderRows, Notes, QueryPlan, QueryRecorder, Repo}
  alias Engram.DataMigrations.{ExplicitFolderReconcile, FolderTable}
  alias Engram.Folders.Rows

  setup do
    # Markers are written here, so the vault keeps release D's path hashes:
    # #2645's write stop is on only once a vault has no marker
    # (`PathHashStop.markers_gone?/2`), and the test env assumes it on.
    Application.put_env(:engram, :path_hash_stop_markers_gone, false)
    on_exit(fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, true) end)
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  # An explicit folder row with no live marker: what a cascade before #2639
  # left on a row it kept (stale, `ExplicitFolderReconcile` clears it), and
  # what a writer leaves once markers stop (phase 2). The marker create makes
  # the explicit row; the marker goes.
  defp explicit_without_marker!(user, vault, folder) do
    {:ok, %{folders: [%{id: id}]}} = Notes.create_folder_markers(user, vault, [folder])
    Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(id)])
    assert FolderRows.tree(user)[folder].explicit
    id
  end

  defp payload_ids(user, vault),
    do: Map.new(Notes.folders_payload(user, vault), &{&1.name, &1.id})

  describe "listings read folders.explicit" do
    test "listings read the flag: an explicit row with no marker is listed everywhere",
         %{user: u, vault: v} do
      id = explicit_without_marker!(u, v, "Empty/Inner")

      assert {:ok, ["Empty/Inner"]} = Notes.list_explicit_folders(u, v)
      {:ok, counts} = Notes.list_folders_with_counts(u, v)
      assert %{"Empty/Inner" => 0} = Map.new(counts, &{&1.folder, &1.count})
      assert payload_ids(u, v)["Empty/Inner"] == id
      assert {:ok, ["Empty/Inner"]} = Notes.resolve_folder_markers(u, v, [id])
    end

    test "a folder only derived from notes is not explicit", %{user: u, vault: v} do
      put_note(u, v, "Derived/n.md")

      assert {:ok, []} = Notes.list_explicit_folders(u, v)
      assert payload_ids(u, v) == %{"Derived" => nil}
    end

    test "a marker made after its folder's row: the row's id is listed, both ids resolve", ctx do
      %{user: u, vault: v} = ctx
      put_note(u, v, "D/n.md")
      row = FolderRows.tree(u)["D"].id
      {:ok, %{folders: [%{id: marker}]}} = Notes.create_folder_markers(u, v, ["D"])
      assert marker != row

      assert payload_ids(u, v)["D"] == row
      # The previous release listed the marker's id: an SPA still holding it works.
      assert {:ok, ["D", "D"]} = Notes.resolve_folder_markers(u, v, [row, marker])
      assert {:ok, %{notes: [_]}} = Notes.list_folder_notes_by_id(u, v, marker)
      assert {:ok, %{notes: [_]}} = Notes.list_folder_notes_by_id(u, v, row)
    end

    test "a non-explicit folder row's id, a malformed id and another vault's id are not found",
         %{user: u, vault: v} do
      put_note(u, v, "D/n.md")
      derived = FolderRows.tree(u)["D"].id
      other = insert(:vault, user: u)
      elsewhere = explicit_without_marker!(u, other, "X")

      for id <- [derived, "not-a-uuid", elsewhere] do
        assert {:error, {:not_found, ^id}} = Notes.resolve_folder_markers(u, v, [id])
      end
    end

    test "control: a self-host whose ledgers are open reads the markers", ctx do
      %{user: u, vault: v} = ctx
      Engram.ServiceConfig.put_override(:explicit_folders_ledger, :read)
      refute Rows.explicit_reads?()

      explicit_without_marker!(u, v, "NoMarker")
      {:ok, %{folders: [%{id: m}]}} = Notes.create_folder_markers(u, v, ["Marked"])

      assert {:ok, ["Marked"]} = Notes.list_explicit_folders(u, v)
      assert payload_ids(u, v) == %{"Marked" => m}
    end
  end

  # The listing's new statement as the app role, under RLS: the partial
  # index, never a read of the vault's or the tenant's folders. At the
  # 40-tenant shape (`tenant_shape!/0`) the policy's tenant is costed as an
  # average tenant, and with no bound `user_id` the custom plan read
  # `folders_user`, every folder of the tenant
  # (docs/context/notes-generic-plan-mis-pick.md, third instance).
  test "plan: the explicit read is the partial index under RLS", %{user: u, vault: v} do
    for i <- 1..400, do: put_note(u, v, "F#{i}/n.md")
    {:ok, _} = Notes.create_folder_markers(u, v, ["E1", "E2"])

    assert_vault_bound_plans!(u, fn -> Notes.list_explicit_folders(u, v) end, fn s ->
      s =~ ~r/FROM "folders".*"explicit"/s
    end)
  end

  # Prod's statistics shape: 40 tenants, so a tenant or a vault is a fraction
  # of `folders`. The physical leftovers of earlier tests are kept (no
  # CLUSTER): the plan must hold on them too. The visibility map is left as
  # the inserts left it, so the partial index wins on its keys, not on an
  # index-only read a restore or CLUSTER would take away.
  defp tenant_shape!(users, vaults) do
    for {col, n} <- [user_id: users, vault_id: vaults],
        do: Repo.query!("ALTER TABLE folders ALTER COLUMN #{col} SET (n_distinct = #{n})")

    Repo.query!("ANALYZE folders")
  end

  # The explicit read (the statement of `fun` that `pick` matches) is bound
  # to the vault in its custom AND its forced generic plan, at the 40-tenant
  # statistics shape, at one where every tenant looks unique, and with dead
  # explicit entries in the partial index (a probe: a partial index holding
  # dead entries is costed as a read of all its pages, and with only
  # `folders_explicit_vault_live` the planner read `folders_user`, every
  # folder of the tenant: #2639's CI). With `folders_explicit_user_vault`
  # it reads one vault. `scope` picks the part of the plan to check (the
  # counts statement's explicit leg).
  defp assert_vault_bound_plans!(user, fun, pick, scope \\ & &1) do
    me = self()
    other_vault_folders!(user)

    for {users, vaults, dead} <- [{40, 40, 0}, {-1, 40, 0}, {40, 40, 1500}] do
      if dead > 0, do: dead_explicit_rows!(dead)
      tenant_shape!(users, vaults)
      {_, queries} = QueryRecorder.record(fun)
      [{sql, params}] = for %{sql: s, params: p, pid: ^me} <- queries, pick.(s), do: {s, p}
      %{custom: custom, generic: generic} = QueryPlan.rls_plans(user.id, sql, params)

      for {kind, plan} <- [custom: custom, generic: generic] do
        assert_scans_vault_bound!(scope.(plan), fn ->
          "#{kind} plan, n_distinct #{users}/#{vaults}, #{dead} dead rows\n" <>
            plan_diagnostics(user, sql, params)
        end)
      end
    end

    assert_never_named!(fun, pick)
  end

  # A second vault of the tenant holding folder rows. With one vault, a
  # `folders_user` read IS the vault's folders and costs the same as a
  # vault-keyed one, so the check could not tell a tenant-wide plan from a
  # vault-bound one; with these, a tenant-wide read visibly crosses vaults.
  defp other_vault_folders!(user) do
    other = insert(:vault, user: user)

    for chunk <- Enum.chunk_every(1..250, 50),
        do: {:ok, _} = Notes.create_folder_markers(user, other, Enum.map(chunk, &"X#{&1}"))

    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM folders WHERE vault_id = $1 AND deleted_at IS NULL", [
        Ecto.UUID.dump!(other.id)
      ])

    assert n >= 200, "precondition: the other vault holds #{n} folder rows"
  end

  # Dead explicit entries in the folder indexes: `n` explicit folder rows of
  # another tenant, inserted and rolled back (a savepoint inside the test's
  # transaction). The sandbox never vacuums them, as CI's runs never do.
  defp dead_explicit_rows!(n) do
    other = insert(:user)
    vault = insert(:vault, user: other)

    Repo.transaction(fn ->
      Repo.query!(
        "INSERT INTO folders (vault_id, user_id, name_ciphertext, name_nonce, name_hmac, " <>
          "dek_version, explicit) SELECT $1, $2, '\\x00', '\\x00', " <>
          "decode(md5(i::text), 'hex'), 1, true FROM generate_series(1, $3) i",
        [Ecto.UUID.dump!(vault.id), Ecto.UUID.dump!(other.id), n]
      )

      Repo.rollback(:dead)
    end)
  end

  # On a failing plan test: the plan with cost estimates, and the statistics
  # the planner costed it from (pg_class sizes of folders and its indexes,
  # pg_stats of the key columns), so a CI-only red reads from the log.
  defp plan_diagnostics(user, sql, params) do
    %{custom: costed} = QueryPlan.rls_plans(user.id, sql, params, costs: true)

    sizes =
      Repo.query!(
        "SELECT c.relname, c.relpages, c.reltuples::bigint FROM pg_class c " <>
          "WHERE c.relname = 'folders' OR c.oid IN " <>
          "(SELECT indexrelid FROM pg_index WHERE indrelid = 'folders'::regclass) ORDER BY 1"
      ).rows

    stats =
      Repo.query!(
        "SELECT attname, n_distinct, null_frac, " <>
          "(SELECT array_agg(round(f::numeric, 4)) FROM unnest(most_common_freqs[1:3]) f) " <>
          "FROM pg_stats WHERE tablename = 'folders' " <>
          "AND attname IN ('user_id', 'vault_id', 'explicit', 'deleted_at', 'parent_id')"
      ).rows

    "costed custom plan:\n#{costed}\nsizes #{inspect(sizes)}\npg_stats #{inspect(stats)}"
  end

  # Every read of folders is bound to the vault: each index scan, index-only
  # scan and bitmap index scan (a BitmapAnd/BitmapOr arm included) on a
  # folders index has a condition naming `vault_id`; `folders_user`
  # (`user_id` alone, every folder of the tenant) is refused outright, and
  # so is a seq scan or an index scan with no condition at all.
  defp assert_scans_vault_bound!(plan, diag \\ fn -> "" end) do
    msg = fn why -> why <> "\n" <> plan <> "\n" <> diag.() end

    refute plan =~ ~r/\bfolders_user\b(?!_)/, msg.("folders_user read")
    refute plan =~ "Seq Scan on folders", msg.("seq scan")

    scans = Regex.scan(~r/Scan using (folders\w*) on folders\b/, plan)
    bitmaps = Regex.scan(~r/Bitmap Index Scan on (folders\w*)/, plan)

    conds =
      Regex.scan(
        ~r/(?:Scan using folders\w* on folders\b|Bitmap Index Scan on folders\w*)[^\n]*\n\s*(?:Index|Recheck) Cond: ([^\n]*)/,
        plan,
        capture: :all_but_first
      )

    assert scans ++ bitmaps != [], msg.("no folders scan")
    assert length(conds) == length(scans) + length(bitmaps), msg.("a scan with no condition")
    for [cond] <- conds, do: assert(cond =~ "vault_id =", msg.("not vault-bound: " <> cond))
  end

  # Past the 5 custom plans a named statement gets before Postgres may switch
  # it to a generic one: each of 7 runs sends the statement, and none
  # prepares it by name (`prepare: :unnamed`), so it only ever runs on a
  # custom plan.
  defp assert_never_named!(fun, pick) do
    me = self()

    sqls =
      for _ <- 1..7 do
        {_, runs} = QueryRecorder.record(fun)
        [sql] = for %{sql: s, pid: ^me} <- runs, pick.(s), uniq: true, do: s
        sql
      end

    for sql <- Enum.uniq(sqls),
        do:
          assert(
            Repo.query!("SELECT 1 FROM pg_prepared_statements WHERE statement = $1", [sql]).rows ==
              [],
            "prepared by name:\n" <> sql
          )
  end

  defp reconcile! do
    IdWindows.reset_walk(ExplicitFolderReconcile.name())

    Enum.reduce_while(1..5, nil, fn _, _ ->
      case ExplicitFolderReconcile.run_pass() do
        :done -> {:halt, :done}
        more -> {:cont, more}
      end
    end)
  end

  # The #2639 review, H1: a row a pre-#2639 cascade left explicit with its
  # marker gone must not be listed, and a path delete must clear it.
  describe "stale explicit rows" do
    test "the reconcile clears a row no live marker names, and keeps a marked one", ctx do
      %{user: u, vault: v} = ctx
      explicit_without_marker!(u, v, "Stale")
      {:ok, _} = Notes.create_folder_markers(u, v, ["Kept"])

      assert reconcile!() == :done
      refute FolderRows.tree(u)["Stale"].explicit
      assert {:ok, ["Kept"]} = Notes.list_explicit_folders(u, v)
      # A second walk finds nothing.
      assert reconcile!() == :done
    end

    test "a path delete (DELETE /folders/<path>) clears a stale row", %{user: u, vault: v} do
      explicit_without_marker!(u, v, "Stale")

      assert {:ok, :deleted} = Notes.delete_folder_marker(u, v, "Stale")
      assert {:ok, []} = Notes.list_explicit_folders(u, v)
      assert {:ok, :not_found} = Notes.delete_folder_marker(u, v, "Stale")
    end

    test "the gate waits for both ledgers", %{user: _u} do
      Engram.ServiceConfig.put_override(:explicit_folders_ledger, :read)
      Engram.DataCase.clear_request_caches()
      refute Rows.explicit_reads?()

      # Either ledger alone is not enough.
      for m <- [FolderTable, ExplicitFolderReconcile] do
        DataMigrations.mark_done(m.name(), m.version())
        Engram.DataCase.clear_request_caches()
        refute Rows.explicit_reads?(), "#{m.name()} alone opened the gate"
        DataMigrations.reopen(m.name(), m.version())
      end

      for m <- [FolderTable, ExplicitFolderReconcile],
          do: DataMigrations.mark_done(m.name(), m.version())

      Engram.DataCase.clear_request_caches()
      assert Rows.explicit_reads?()
    end

    test "kill switch: off, the reconcile is disabled" do
      Engram.ServiceConfig.put_override(:explicit_folder_reconcile, false)
      refute ExplicitFolderReconcile.enabled?()
    end
  end

  # The #2639 review, M1: the cascade's marker leg clears the flag even when
  # the folder row is kept (here: content, and no rows leg at all).
  test "a cascade that deletes a marker clears the flag on the row it keeps", ctx do
    %{user: u, vault: v} = ctx
    {:ok, _} = Notes.create_folder_markers(u, v, ["K"])
    put_note(u, v, "K/n.md")
    {:ok, rows} = Notes.scan_folders(u, v, ["K"])
    marker_rows = Enum.filter(rows, &(&1.kind == "folder"))

    assert {:ok, %{deleted: 1}} = Notes.delete_scanned(u, v, marker_rows)
    assert {:ok, []} = Notes.list_explicit_folders(u, v)
    {:ok, counts} = Notes.list_folders_with_counts(u, v)
    assert %{"K" => 1} = Map.new(counts, &{&1.folder, &1.count})
  end

  # E -> D rollback: an empty folder E made carries `explicit_seq` and no
  # marker. D deletes it, then undoes the delete: with no trashed marker to
  # bring the flag back, the trashed row must keep it.
  test "an undo in D brings back an empty folder E made (explicit_seq, no marker)", ctx do
    %{user: u, vault: v} = ctx
    {:ok, _} = Notes.create_folder_markers(u, v, ["E"])
    Repo.query!("DELETE FROM notes WHERE vault_id = $1 AND kind = 'folder'", [dump(v.id)])
    Repo.query!("UPDATE folders SET explicit_seq = 7 WHERE id = $1", [dump(row_id(u, "E"))])
    assert {:ok, ["E"]} = Notes.list_explicit_folders(u, v)
    op = Ecto.UUID.generate()

    assert {:ok, _} = Engram.Folders.delete(u, v, "E", recursive: true, op_id: op)
    assert {:ok, []} = Notes.list_explicit_folders(u, v)
    assert {:ok, _} = Engram.Folders.restore_op(u, v, op)
    assert {:ok, ["E"]} = Notes.list_explicit_folders(u, v)
  end

  # The rows leg alone (no marker left to clear the flag first, as a
  # cascade's marker leg does): a D-era row is trashed with its flag
  # cleared, as before the fix above.
  test "a D-era row (explicit_seq NULL) still loses its flag when deleted", ctx do
    %{user: u, vault: v} = ctx
    {:ok, _} = Notes.create_folder_markers(u, v, ["D"])
    Repo.query!("DELETE FROM notes WHERE vault_id = $1 AND kind = 'folder'", [dump(v.id)])
    id = row_id(u, "D")

    assert 1 =
             Repo.with_tenant!(u.id, fn ->
               Rows.soft_delete(u, v.id, ["D"], Ecto.UUID.generate())
             end)

    assert %{rows: [[false, nil, true]]} =
             Repo.query!(
               "SELECT explicit, explicit_seq, deleted_at IS NOT NULL FROM folders WHERE id = $1",
               [dump(id)]
             )
  end

  defp row_id(user, path), do: FolderRows.tree(user)[path].id
  defp dump(id), do: Ecto.UUID.dump!(id)

  # The #2639 review, L2: the folder counts' explicit leg as the app role.
  test "plan: the counts' explicit leg is the partial index under RLS", %{user: u, vault: v} do
    for i <- 1..400, do: put_note(u, v, "F#{i}/n.md")
    {:ok, _} = Notes.create_folder_markers(u, v, ["E1", "E2"])

    assert_vault_bound_plans!(
      u,
      fn ->
        # The listing caches the counts under the vault seq.
        Engram.Cache.clear_local(:vault_scan)
        Engram.DataCase.clear_request_caches()
        Notes.list_folders_with_counts(u, v)
      end,
      &(&1 =~ "UNION ALL" and &1 =~ ~r/"explicit"/),
      &explicit_leg/1
    )
  end

  # The counts statement's explicit leg (leg 6, the union's second part) as
  # its own plan subtree: the lines under `"*SELECT* 2"`, by indentation.
  defp explicit_leg(plan) do
    lines = String.split(plan, "\n")
    start = Enum.find_index(lines, &(&1 =~ ~s("*SELECT* 2")))
    assert start, "no explicit leg:\n" <> plan
    indent = fn line -> byte_size(line) - byte_size(String.trim_leading(line)) end
    depth = indent.(Enum.at(lines, start))

    leg =
      lines
      |> Enum.drop(start + 1)
      |> Enum.take_while(&(indent.(&1) > depth or String.trim(&1) == ""))

    leg = Enum.join([Enum.at(lines, start) | leg], "\n")
    assert leg =~ "explicit", "the second part is not the explicit leg:\n" <> plan
    leg
  end

  # The counts' folder-rows leg (leg 5, every folder row of the vault) as the
  # app role, at the 40-tenant shape, for a user with a second, bigger vault.
  # With only the policy's tenant it read `folders_user`: every folder of
  # every vault of the user. Each folder scan must lead with `vault_id`. Its
  # generic plan still reads `folders_user` (a bound tenant is costed as an
  # average one), so the statement runs unnamed: the custom plan is the
  # only one it gets, and it never runs on a generic plan.
  # KNOWN GAP, pre-existing on main: the counts' folder-rows leg (leg 5,
  # every folder row of the vault, explicit or not, live or not) has no
  # explicit predicate for a partial index to match, so its only
  # tenant-and-vault path is a full index, and a full `(user_id, vault_id)`
  # index breaks the folder walk (`WalkIndexCondTest`). With `folders_user
  # (user_id)` present the planner can read every folder of the tenant for
  # it (a probe at 0 to 20,000 dead rows did). The fix is dropping
  # `folders_user`, a schema decision (follow-up to #2639). When it lands
  # this test fails: invert it into a strict `assert_vault_bound_plans!`
  # check on the leg.
  test "known gap: the counts' folder-rows leg can read folders_user (pre-existing on main)" do
    indexes =
      Repo.query!("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'folders'").rows

    assert Enum.any?(indexes, fn [name, _] -> name == "folders_user" end),
           "folders_user is gone: the known gap is fixed, invert this test"

    refute Enum.any?(indexes, fn [_, defn] ->
             defn =~ ~r/\(user_id, vault_id[,)]/ and not (defn =~ " WHERE ")
           end),
           "a full (user_id, vault_id) index exists: check the walk and invert this test"
  end

  test "the folders scan check refuses tenant-wide, unconditioned and seq scans" do
    good = """
    ->  Index Only Scan using folders_explicit_vault_live on folders f0 (actual rows=2.00 loops=1)
          Index Cond: (vault_id = 'v'::uuid)
    ->  Bitmap Heap Scan on folders f0_1 (actual rows=40.00 loops=1)
          Recheck Cond: ((user_id = 'u'::uuid) AND (vault_id = 'v'::uuid))
          ->  Bitmap Index Scan on folders_explicit_user_vault (actual rows=40.00 loops=1)
                Index Cond: ((user_id = 'u'::uuid) AND (vault_id = 'v'::uuid))
    """

    assert_scans_vault_bound!(good)

    for bad <- [
          # the tenant's whole folder index
          "->  Index Scan using folders_user on folders f2 (actual rows=2.00 loops=1)\n" <>
            "      Index Cond: (user_id = 'u'::uuid)\n",
          # folders_user as one arm of a BitmapAnd whose other arm is vault-bound
          "->  Bitmap Heap Scan on folders f2 (actual rows=2.00 loops=1)\n" <>
            "      Recheck Cond: ((vault_id = 'v'::uuid) AND (user_id = 'u'::uuid))\n" <>
            "      ->  BitmapAnd\n" <>
            "            ->  Bitmap Index Scan on folders_parent_all_ids\n" <>
            "                  Index Cond: (vault_id = 'v'::uuid)\n" <>
            "            ->  Bitmap Index Scan on folders_user\n" <>
            "                  Index Cond: (user_id = 'u'::uuid)\n",
          # a bitmap arm on another index with no vault condition
          "->  Bitmap Heap Scan on folders f2 (actual rows=2.00 loops=1)\n" <>
            "      Recheck Cond: (parent_id = 'p'::uuid)\n" <>
            "      ->  Bitmap Index Scan on folders_parent_name_keys\n" <>
            "            Index Cond: (parent_id = 'p'::uuid)\n",
          # a full index scan, no condition at all
          "->  Index Scan using folders_pkey on folders f2 (actual rows=2.00 loops=1)\n" <>
            "      Filter: (vault_id = 'v'::uuid)\n",
          # a seq scan
          "->  Seq Scan on folders f2 (actual rows=2.00 loops=1)\n" <>
            "      Filter: (vault_id = 'v'::uuid)\n"
        ] do
      assert_raise ExUnit.AssertionError, fn -> assert_scans_vault_bound!(good <> bad) end
    end
  end

  # The folder marker delete (S6 step 4) matches a marker to its row by path
  # hash, and #2645's write stop leaves rows without one: a marker written on
  # an existing row must give it the marker's hash (missing or stale).
  test "a marker on an existing row writes the row's missing or stale path hash", ctx do
    %{user: u, vault: v} = ctx
    put_note(u, v, "H/n.md")
    put_note(u, v, "S/n.md")
    tree = FolderRows.tree(u)

    Repo.query!("UPDATE folders SET full_path_hmac = NULL WHERE id = $1", [
      Ecto.UUID.dump!(tree["H"].id)
    ])

    Repo.query!("UPDATE folders SET full_path_hmac = '\\x00' WHERE id = $1", [
      Ecto.UUID.dump!(tree["S"].id)
    ])

    {:ok, _} = Notes.create_folder_markers(u, v, ["H", "S"])

    for folder <- ["H", "S"] do
      %{rows: [[row_hash, marker_hash]]} =
        Repo.query!(
          "SELECT f.full_path_hmac, n.folder_hmac FROM folders f JOIN notes n " <>
            "ON n.vault_id = f.vault_id AND n.kind = 'folder' AND n.deleted_at IS NULL " <>
            "AND n.folder_hmac = f.full_path_hmac WHERE f.id = $1",
          [Ecto.UUID.dump!(tree[folder].id)]
        )

      assert is_binary(marker_hash) and row_hash == marker_hash, folder
    end
  end

  # The marker-hash write is ONE statement per ensure call, whatever the
  # number of markers: `PathHmacs.put/3`, which compares each named row's
  # stored hash and writes only a mismatch (its plan, primary-key and
  # `folders_full_path` probes: `PathHmacsPlanTest`).
  test "the marker hash write is one statement per ensure call", %{user: u, vault: v} do
    for f <- ~w(H1 H2 H3), do: put_note(u, v, "#{f}/n.md")
    me = self()

    {_, queries} =
      QueryRecorder.record(fn -> {:ok, _} = Notes.create_folder_markers(u, v, ~w(H1 H2 H3)) end)

    puts = for %{sql: s, pid: ^me} <- queries, s =~ "IS DISTINCT FROM t.fh", do: s
    assert length(puts) == 1
  end

  # A stale stored hash replaced by the marker's: `PathHmacs.put/3` releases
  # the marker's hash from any other live row first (a mixed-window leftover
  # holding it), so exactly one live row holds it after, the marker's.
  test "a marker's hash taken from another live holder leaves exactly one", ctx do
    %{user: u, vault: v} = ctx
    put_note(u, v, "H/n.md")
    put_note(u, v, "X/n.md")
    tree = FolderRows.tree(u)
    [h, x] = Enum.map(["H", "X"], &Ecto.UUID.dump!(tree[&1].id))

    Repo.query!(
      "UPDATE folders SET full_path_hmac = (SELECT full_path_hmac FROM folders WHERE id = $1) " <>
        "WHERE id = $2",
      [h, x]
    )

    Repo.query!("UPDATE folders SET full_path_hmac = NULL WHERE id = $1", [h])
    {:ok, _} = Notes.create_folder_markers(u, v, ["H"])

    %{rows: holders} =
      Repo.query!(
        "SELECT f.id FROM folders f JOIN notes n ON n.vault_id = f.vault_id " <>
          "AND n.kind = 'folder' AND n.deleted_at IS NULL AND n.folder_hmac = f.full_path_hmac " <>
          "WHERE f.vault_id = $1 AND f.deleted_at IS NULL",
        [Ecto.UUID.dump!(v.id)]
      )

    assert holders == [[h]]
  end

  # A batch move whose target is a folder ROW id (what the listings hand out
  # since the flag reads) with no marker behind it.
  test "batch_move_notes into an explicit folder given by its row id", %{user: u, vault: v} do
    explicit_without_marker!(u, v, "Target")
    row_id = FolderRows.tree(u)["Target"].id
    note = put_note(u, v, "n.md")

    assert {:ok, %{moved: 1}} = Notes.batch_move_notes(u, v, [note.id], row_id)
    assert {:ok, %{path: "Target/n.md"}} = Notes.get_note(u, v, "Target/n.md")
  end

  # The #2649 review, H1: an empty explicit folder with no marker is a bare
  # folder row; every rename and move surface must move it.
  describe "renaming an empty explicit folder with no marker" do
    test "Folders.rename moves it and reports the folder", %{user: u, vault: v} do
      explicit_without_marker!(u, v, "Empty")

      assert {:ok, %{notes: 0, attachments: 0, folders: 1}} =
               Engram.Folders.rename(u, v, "Empty", "Renamed")

      assert {:ok, ["Renamed"]} = Notes.list_explicit_folders(u, v)
    end

    test "MCP rename_folder moves it", %{user: u, vault: v} do
      explicit_without_marker!(u, v, "Empty")

      assert {:ok, _, _} =
               Engram.MCP.Handlers.handle("rename_folder", u, v, %{
                 "old_folder" => "Empty",
                 "new_folder" => "R2"
               })

      assert {:ok, ["R2"]} = Notes.list_explicit_folders(u, v)
    end

    test "a batch move by id moves it", %{user: u, vault: v} do
      id = explicit_without_marker!(u, v, "Empty")
      {:ok, %{folders: [%{id: _}]}} = Notes.create_folder_markers(u, v, ["Into"])

      assert {:ok, _} = Engram.Folders.batch_move(u, v, [id], {:path, "Into"})
      assert {:ok, ["Into", "Into/Empty"]} = Notes.list_explicit_folders(u, v)
    end

    test "control: a bare derived row is still not found over REST/MCP", %{user: u, vault: v} do
      n = put_note(u, v, "D/n.md")
      :ok = Notes.delete_note(u, v, n.path)

      assert {:ok, %{notes: 0, attachments: 0, folders: 0}} =
               Engram.Folders.rename(u, v, "D", "E")

      assert {:error, {:folder_not_found, _}} =
               Engram.MCP.Handlers.handle("rename_folder", u, v, %{
                 "old_folder" => "D",
                 "new_folder" => "E"
               })
    end

    # The #2639 review: an explicit folder of attachments only (images) moves,
    # and the attachments with it; the bare recheck counts notes only.
    test "an explicit folder holding only attachments moves with them", %{user: u, vault: v} do
      explicit_without_marker!(u, v, "Pics")

      {:ok, _} =
        Engram.Attachments.upsert_attachment(u, v, %{
          "path" => "Pics/a.png",
          "content_base64" => Base.encode64("png")
        })

      assert {:ok, %{notes: 0, attachments: 1, folders: 1}} =
               Engram.Folders.rename(u, v, "Pics", "Photos")

      assert {:ok, ["Photos"]} = Notes.list_explicit_folders(u, v)
      {:ok, metas} = Engram.Attachments.list_attachments(u, v)
      assert Enum.map(metas, & &1.path) == ["Photos/a.png"]
    end

    # The #2639 review: content written under the folder after the rename's
    # scan, before its lock. The move sees it under the vault lock and asks
    # for a re-plan, so the note is cascaded, never left at the old path.
    test "a note that lands after the scan is cascaded, not left behind", %{user: u, vault: v} do
      explicit_without_marker!(u, v, "Late")
      put_note(u, v, "Late/n.md")

      assert {:error, :claims_stale} =
               Repo.with_tenant!(u.id, fn ->
                 Rows.move_bare_explicit(u, v.id, "Late", "Moved")
               end)

      assert {:ok, %{notes: 1, folders: 0}} = Engram.Folders.rename(u, v, "Late", "Moved")
      assert {:ok, _} = Notes.get_note(u, v, "Moved/n.md")
    end
  end

  # The 2639 audit: release C (0.89.0) still serves during the rollout to D,
  # or after a rollback and re-roll, and writes after the reconcile closed.
  # Each read switch, given 0.89.0's own write (raw SQL where its code
  # differs from D's), must read right. D's writers are unchanged except the
  # cascade's marker leg and the path delete, so creates, renames and undos
  # are 0.89.0's own code here.
  describe "0.89.0 writes, D reads" do
    # 0.89.0's recursive delete of an empty explicit folder: the marker leg
    # tombstones the marker WITHOUT clearing the flag (D's leg clears it),
    # then the rows leg soft-deletes the row with explicit false.
    defp c_delete!(user, folder, opts) do
      %{id: row} = FolderRows.tree(user)[folder]

      Repo.query!(
        "UPDATE notes SET deleted_at = now() WHERE kind = 'folder' AND user_id = $1 " <>
          "AND deleted_at IS NULL AND folder_hmac = (SELECT full_path_hmac FROM folders WHERE id = $2)",
        [Ecto.UUID.dump!(user.id), Ecto.UUID.dump!(row)]
      )

      if opts[:rows_leg],
        do:
          Repo.query!(
            "UPDATE folders SET deleted_at = now(), explicit = false WHERE id = $1",
            [Ecto.UUID.dump!(row)]
          )
    end

    test "create: a 0.89.0 folder create is listed", %{user: u, vault: v} do
      {:ok, _} = Notes.create_folder_markers(u, v, ["C"])
      assert {:ok, ["C"]} = Notes.list_explicit_folders(u, v)
      assert %{"C" => _} = payload_ids(u, v)
    end

    test "rename: a 0.89.0 folder rename is listed at the new path", %{user: u, vault: v} do
      {:ok, _} = Notes.create_folder_markers(u, v, ["Old"])
      {:ok, _} = Notes.rename_folder(u, v, "Old", "New")
      assert {:ok, ["New"]} = Notes.list_explicit_folders(u, v)
    end

    test "delete: a whole 0.89.0 delete is not listed", %{user: u, vault: v} do
      {:ok, _} = Notes.create_folder_markers(u, v, ["Gone"])
      c_delete!(u, "Gone", rows_leg: true)
      assert {:ok, []} = Notes.list_explicit_folders(u, v)
    end

    # The audit's ghost: the marker leg ran, the rows leg did not (or kept
    # the row). The closed ledger's daily re-verify walk clears it.
    test "delete: a 0.89.0 delete that kept the row is cleared by the re-verify", ctx do
      %{user: u, vault: v} = ctx
      {:ok, _} = Notes.create_folder_markers(u, v, ["Ghost"])
      c_delete!(u, "Ghost", rows_leg: false)
      assert {:ok, ["Ghost"]} = Notes.list_explicit_folders(u, v)

      assert ExplicitFolderReconcile.reverify?()
      assert reconcile!() == :done
      assert {:ok, []} = Notes.list_explicit_folders(u, v)
    end

    test "undo: a 0.89.0 undo of an empty folder delete is listed again", %{user: u, vault: v} do
      {:ok, _} = Notes.create_folder_markers(u, v, ["U"])
      op = Ecto.UUID.generate()
      {:ok, _} = Engram.Folders.delete(u, v, "U", recursive: true, op_id: op)
      assert {:ok, []} = Notes.list_explicit_folders(u, v)
      {:ok, _} = Engram.Folders.restore_op(u, v, op)
      assert {:ok, ["U"]} = Notes.list_explicit_folders(u, v)
    end
  end

  # The 2639 / 2649 re-review: after a rollback E -> D, D's daily walk must
  # not clear a folder E made explicit with no marker (`explicit_seq` set),
  # or the plugin trashes it.
  test "rollback E -> D: the walk keeps an E-style folder (explicit_seq, no marker)", ctx do
    %{user: u, vault: v} = ctx
    {:ok, %{folders: [%{id: m}]}} = Notes.create_folder_markers(u, v, ["FromE"])
    %{id: row} = FolderRows.tree(u)["FromE"]
    Repo.query!("UPDATE folders SET explicit_seq = 7 WHERE id = $1", [Ecto.UUID.dump!(row)])
    Repo.query!("DELETE FROM notes WHERE id = $1", [Ecto.UUID.dump!(m)])

    assert reconcile!() == :done
    assert FolderRows.tree(u)["FromE"].explicit
    assert {:ok, ["FromE"]} = Notes.list_explicit_folders(u, v)
  end

  # The re-review: a closed ledger's walk repairs a ghost in place and stays
  # closed, so listings never flap back to the markers.
  test "a closed ledger's walk repairs a ghost and stays closed", %{user: u, vault: v} do
    explicit_without_marker!(u, v, "Ghost2")
    DataMigrations.mark_done(ExplicitFolderReconcile.name(), ExplicitFolderReconcile.version())

    on_exit(fn ->
      DataMigrations.forget(ExplicitFolderReconcile.name(), ExplicitFolderReconcile.version())
    end)

    IdWindows.reset_walk(ExplicitFolderReconcile.name())

    assert ExplicitFolderReconcile.run_pass() == :done
    refute FolderRows.tree(u)["Ghost2"].explicit

    assert DataMigrations.completed_at(
             ExplicitFolderReconcile.name(),
             ExplicitFolderReconcile.version()
           )
  end

  # The re-review: the walk's statements as the fleet role, on a realistic
  # vault (notes, markers, explicit rows; ANALYZE): index probes, no scan.
  test "plans: the reconcile's statements as engram_maintenance", %{user: u, vault: v} do
    for i <- 1..200 do
      {:ok, _} =
        Notes.upsert_note(u, v, %{"path" => "F#{rem(i, 20)}/n#{i}.md", "content" => "x"},
          actor: "api"
        )
    end

    {:ok, _} = Notes.create_folder_markers(u, v, Enum.map(1..10, &"M#{&1}"))
    for t <- ["notes", "folders", "vaults"], do: Repo.query!("ANALYZE #{t}")

    ids =
      u |> FolderRows.tree() |> Map.values() |> Enum.map(&Ecto.UUID.dump!(&1.id)) |> Enum.take(20)

    vaults = [Ecto.UUID.dump!(v.id)]

    for {sql, params} <- [
          {ExplicitFolderReconcile.lock_vaults_sql(), [ids]},
          {ExplicitFolderReconcile.clear_sql(), [ids, vaults]},
          {ExplicitFolderReconcile.left_sql(), [ids]}
        ] do
      %{custom: custom, generic: generic} =
        QueryPlan.rls_plans(u.id, sql, params, role: "engram_maintenance")

      for plan <- [custom, generic] do
        refute plan =~ ~r/Seq Scan on (notes|folders|vaults)/, plan
        if sql =~ "kind = 'folder'", do: assert(plan =~ "notes_user_vault_folder_marker", plan)
      end
    end
  end
end
