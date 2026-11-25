defmodule Engram.Folders.WalkIndexCondTest do
  # The folder walk (`Engram.Folders.WalkSql`: `walk_many/0` behind
  # `Rows.ids_by_path/3`, `ids_at/3` and `check_move/4`, and the single-path
  # walk behind `Rows.id_by_walk/3` and the S3 name match) must be one probe
  # per level, whatever the siblings at that level.
  #
  # Staging 0.87.0 (2026-11-16): below the root every probe read
  # `folders_live_parent_id` (`(vault_id, parent_id, id) INCLUDE (user_id)`)
  # with `name_hmac` only a Filter, so it read every sibling. Superuser and
  # engram_app picked the same plan, so it is not RLS. The planner treats
  # `vault_id` and `parent_id` as independent: `rows x 1/n_distinct(vault)
  # x 1/n_distinct(parent)` (staging 1,436 x 1/8 x 1/412 = 0.43), clamped
  # to 1 row, the same 1 row the unique name probe gets. So both cost one
  # index and one heap page, 8.30 vs 8.43, the gap only btree height (the
  # churned `folders_live_name` is a level taller). The more vaults and
  # parents, the lower that estimate, so the tie is structural; the real
  # sibling count never enters it. `folders_live_name_ids` adds INCLUDE
  # (user_id, id), so the walk is an index-only scan on its key (no heap
  # page), which no plain scan of another index ties.
  #
  # The setup: `n_distinct = 40` on the tenant columns (the prod-shape
  # convention of the other plan tests; staging has 3 users and 8 vaults),
  # staging's measured parent_id ratio, and all-visible pages as a vacuumed
  # table's (staging: 577 of 607). Not async: ALTER TABLE, CLUSTER and the
  # role drop.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, FolderRows, QueryPlan, QueryRecorder, Repo}
  alias Engram.Folders.Rows

  @big 500
  @small 5

  setup ctx do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    paths =
      for(i <- 1..@big, do: "Big/S#{i}") ++
        for(i <- 1..@small, do: "Small/S#{i}") ++
        ["Big/S250/Leaf", "Small/S3/Leaf"]

    {:ok, _} = Repo.with_tenant!(user.id, fn -> Rows.ensure_all(user, vault.id, paths) end)

    Repo.query!("ALTER TABLE folders ALTER COLUMN vault_id SET (n_distinct = 40)")
    Repo.query!("ALTER TABLE folders ALTER COLUMN user_id SET (n_distinct = 40)")
    Repo.query!("ALTER TABLE folders ALTER COLUMN parent_id SET (n_distinct = -0.29)")
    QueryPlan.fresh!("folders")
    _ = unless ctx[:not_vacuumed], do: QueryPlan.all_visible!(["folders"])

    %{user: user, vault: vault}
  end

  defp plans(user, fun, pattern) do
    {_, queries} = QueryRecorder.record(fn -> Repo.with_tenant!(user.id, fun) end)
    me = self()
    [{sql, params}] = for %{sql: s, params: p, pid: ^me} <- queries, s =~ pattern, do: {s, p}
    QueryPlan.rls_plans(user.id, sql, params)
  end

  # Every walk probe of `folders` in `plan` (any scan but the primary-key
  # read of the walk's result) keys `name_hmac` in its Index Cond, and no
  # Filter of the plan tests it.
  defp assert_name_in_index_cond(plan) do
    lines = String.split(plan, "\n")

    scans =
      for {line, i} <- Enum.with_index(lines),
          line =~ ~r/Scan.* on folders /,
          not (line =~ "folders_pkey"),
          do: i

    assert scans != [], plan

    for i <- scans do
      cond = lines |> Enum.drop(i + 1) |> Enum.find(&(&1 =~ ~r/Index Cond:|Scan/))
      assert cond =~ "Index Cond:" and cond =~ "name_hmac", "no name_hmac key:\n#{plan}"
    end

    refute Enum.any?(lines, &(&1 =~ "Filter:" and &1 =~ "name_hmac")), plan
  end

  test "walk_many: name_hmac keys every level, buffers flat in the siblings",
       %{user: u, vault: v} do
    walk = fn path ->
      plans(u, fn -> Rows.ids_by_path(u, v.id, [path]) end, "WITH RECURSIVE q")
    end

    big = walk.("Big/S250/Leaf")
    small = walk.("Small/S3/Leaf")

    for plan <- [big.custom, big.generic, small.custom, small.generic],
        do: assert_name_in_index_cond(plan)

    # 3 prefixes each: one probe a level, whatever the siblings.
    assert QueryPlan.buffers(big.custom) == QueryPlan.buffers(small.custom), big.custom
    assert QueryPlan.buffers(big.generic) == QueryPlan.buffers(small.generic), big.generic
    assert QueryPlan.buffers(big.custom) <= 3 * 3, big.custom
  end

  # S6 step 3: the writers find a path's rows with the same walk (no
  # `full_path_hmac` read), so `ensure/4` costs one probe a level too.
  test "ensure's walk (the writers' read): name_hmac keys every level, buffers flat",
       %{user: u, vault: v} do
    walk = fn path ->
      plans(u, fn -> Rows.ensure(u, v.id, path) end, "WITH RECURSIVE q")
    end

    big = walk.("Big/S250/Leaf")
    small = walk.("Small/S3/Leaf")

    for plan <- [big.custom, big.generic, small.custom, small.generic],
        do: assert_name_in_index_cond(plan)

    assert QueryPlan.buffers(big.custom) == QueryPlan.buffers(small.custom), big.custom
    assert QueryPlan.buffers(big.generic) == QueryPlan.buffers(small.generic), big.generic
    assert QueryPlan.buffers(big.custom) <= 3 * 3, big.custom
  end

  # Staging 0.87.1 (2026-11-17, row 11c): with pages not all-visible, an
  # index-only scan costs a heap page like any other, so the live name
  # index tied a non-partial `(vault_id, parent_id, id)` index (#2609's
  # `folders_parent_all_ids`, or `folders_parent`) at 8.30 and lost: every
  # level read siblings until the name matched. Every walk probe must key
  # `name_hmac` however vacuumed the table is: the parent-keyed indexes
  # carry it after `parent_id` (`folders_parent_name_ids`), so whichever
  # wins, the name is keyed.
  @tag :not_vacuumed
  test "walk_many on a table not yet vacuumed: name_hmac still keys every level",
       %{user: u, vault: v} do
    walk = fn path ->
      plans(u, fn -> Rows.ids_by_path(u, v.id, [path]) end, "WITH RECURSIVE q")
    end

    big = walk.("Big/S250/Leaf")
    small = walk.("Small/S3/Leaf")

    for plan <- [big.custom, big.generic, small.custom, small.generic],
        do: assert_name_in_index_cond(plan)

    assert QueryPlan.buffers(big.custom) == QueryPlan.buffers(small.custom), big.custom
    assert QueryPlan.buffers(big.generic) == QueryPlan.buffers(small.generic), big.generic
  end

  # The parent FK's check (a hard delete of a folder, or a parent_id
  # update) looks up children by `(vault_id, parent_id)`: it must still be
  # an index probe on the prefix of `folders_parent_name_ids` now that
  # `folders_parent` is gone. Postgres runs it as a cached (generic) plan,
  # as the table owner.
  test "the parent FK's child lookup probes the (vault_id, parent_id) prefix",
       %{user: u, vault: v} do
    big = Repo.with_tenant!(u.id, fn -> Rows.id_by_walk(u, v.id, "Big") end)

    # The FK is composite, (vault_id, parent_id) -> folders (vault_id, id),
    # so its child lookup binds both columns and a vault_id-led index serves it.
    %{rows: [[cols]]} =
      Repo.query!("""
      SELECT array_agg(a.attname::text ORDER BY k.ord)
      FROM pg_constraint c
      CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
      WHERE c.conname = 'folders_parent_fk'
      """)

    assert cols == ["vault_id", "parent_id"]

    {:ok, plan} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL plan_cache_mode = force_generic_plan")

        Repo.query!(
          "PREPARE fk_check(uuid, uuid) AS SELECT 1 FROM ONLY folders x " <>
            "WHERE $1 OPERATOR(pg_catalog.=) vault_id AND $2 OPERATOR(pg_catalog.=) parent_id " <>
            "FOR KEY SHARE OF x"
        )

        %{rows: rows} = Repo.query!("EXPLAIN EXECUTE fk_check('#{v.id}', '#{big}')")

        Repo.query!("DEALLOCATE fk_check")
        rows |> List.flatten() |> Enum.join("\n")
      end)

    assert plan =~ ~r/Index (Only )?Scan using folders_parent_name_ids on folders/, plan
    assert plan =~ ~r/Index Cond: \(\(vault_id = \$1\) AND \(parent_id = \$2\)\)/, plan
  end

  test "id_by_walk (the walk the S3 name match embeds): the same, custom and generic",
       %{user: u, vault: v} do
    walk = fn path ->
      plans(u, fn -> Rows.id_by_walk(u, v.id, path) end, "WITH RECURSIVE w")
    end

    big = walk.("Big/S250/Leaf")
    small = walk.("Small/S3/Leaf")

    for plan <- [big.custom, big.generic, small.custom, small.generic],
        do: assert_name_in_index_cond(plan)

    assert QueryPlan.buffers(big.custom) == QueryPlan.buffers(small.custom), big.custom
    assert QueryPlan.buffers(big.generic) == QueryPlan.buffers(small.generic), big.generic
  end

  test "ensure_all's conflict read (the live child by name) is one probe too",
       %{user: u, vault: v} do
    {:ok, fk} = Crypto.dek_filter_key(u)

    # A racing creator commits the row right after `ensure_all`'s walk
    # missed it, so the insert conflicts and `ensure_all` reads it by
    # `(parent, name)`. The probe statement (the only one keyed by name and
    # parent and not by id) is matched on main's shape too, so main fails
    # on its plan, not on a missing statement.
    conflict_plans = fn parent ->
      parent_id = Repo.with_tenant!(u.id, fn -> Rows.id_by_walk(u, v.id, parent) end)
      path = parent <> "/Orphan"

      plans(
        u,
        fn ->
          orphan =
            after_walk(fn ->
              FolderRows.insert!(u, v, Rows.name_hmac(fk, "Orphan"), parent: parent_id)
            end)

          assert {:ok, %{^path => id}} = Rows.ensure_all(u, v.id, [path])
          assert id == orphan.()
        end,
        ~r/^SELECT f0\."id"(, f0\."explicit")? FROM "folders" AS f0 WHERE (?!.*f0\."id" = ).*"name_hmac" = .*"parent_id" = /
      )
    end

    big = conflict_plans.("Big")
    small = conflict_plans.("Small")

    for plan <- [big.custom, big.generic, small.custom, small.generic],
        do: assert_name_in_index_cond(plan)

    assert QueryPlan.buffers(big.custom) == QueryPlan.buffers(small.custom), big.custom
    assert QueryPlan.buffers(big.generic) == QueryPlan.buffers(small.generic), big.generic
  end

  test "ensure_all's conflict read never returns a row tombstoned after its probe",
       %{user: u, vault: v} do
    # The race the two statements open: the probe finds the live row, then
    # it is tombstoned before the read by key. A telemetry handler tombstones
    # it right after the probe; the read by key must apply the probe's live
    # predicate, or it hands back a dead row as live.
    {:ok, fk} = Crypto.dek_filter_key(u)
    big = Repo.with_tenant!(u.id, fn -> Rows.id_by_walk(u, v.id, "Big") end)
    # A racing creator, right after the walk missed the row (see above).
    orphan_id =
      after_walk(fn -> FolderRows.insert!(u, v, Rows.name_hmac(fk, "Orphan"), parent: big) end)

    orphan = fn -> orphan_id.() end
    me = self()

    tombstone = fn ->
      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [
        Ecto.UUID.dump!(orphan.())
      ])

      send(me, :tombstoned)
    end

    :telemetry.attach(
      "tombstone-after-probe",
      [:engram, :repo, :query],
      fn _, _, %{query: sql}, _ ->
        if sql =~ ~r/^SELECT f0\."id" FROM "folders" AS f0 WHERE (?!.*f0\."id" = ).*"name_hmac"/,
          do: tombstone.()
      end,
      nil
    )

    try do
      {:ok, %{"Big/Orphan" => id}} =
        Repo.with_tenant!(u.id, fn -> Rows.ensure_all(u, v.id, ["Big/Orphan"]) end)

      assert_received :tombstoned
      # The tombstoned row is not handed back as live: a fresh row is made.
      refute id == orphan.()
    after
      :telemetry.detach("tombstone-after-probe")
    end
  end

  # Runs `insert` (a racing creator) once, right after the next walk
  # statement (`WalkSql.walk_many/0`) of this process; returns a fun that
  # gives the id it made. The writers find rows by that walk (S6 step 3), so
  # a row is missed only when it lands after it.
  defp after_walk(insert) do
    me = self()
    key = {__MODULE__, :after_walk, make_ref()}
    name = "after-walk-#{inspect(key)}"

    :telemetry.attach(
      name,
      [:engram, :repo, :query],
      fn _, _, %{query: sql}, _ ->
        if self() == me and sql =~ "WITH RECURSIVE q" and Process.get(key) == nil do
          Process.put(key, :running)
          Process.put(key, insert.())
          :telemetry.detach(name)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
    fn -> Process.get(key) end
  end
end
