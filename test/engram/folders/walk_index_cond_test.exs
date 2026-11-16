defmodule Engram.Folders.WalkIndexCondTest do
  # The folder walk (`Engram.Folders.WalkSql`: `walk_many/0` behind
  # `Rows.ids_by_path/3`, `ids_at/3` and `check_move/4`, and the single-path
  # walk behind `Rows.id_by_walk/3` and the S3 name match) must be one probe
  # per level, whatever the siblings at that level.
  #
  # Staging 0.87.0 (2026-11-16): below the root every probe read
  # `folders_live_parent_id` (`(vault_id, parent_id, id) INCLUDE (user_id)`)
  # with `name_hmac` only a Filter, so it read every sibling. Superuser and
  # engram_app picked the same plan, so it is not RLS. The planner costs a
  # probe keyed by `parent_id = <outer row>` at the average siblings (staging
  # `parent_id` n_distinct -0.29, about 3 children a parent), and with the
  # heap in parent order that index costs the same one page as the unique
  # name index: 8.30 vs 8.43, the difference only the btree height. A tie
  # broken by height cannot be what makes a 5,000-child folder cost one
  # probe. `folders_live_name_ids` adds INCLUDE (user_id, id), so the walk
  # is an index-only scan on its key (no heap page), which no plain scan of
  # another index ties.
  #
  # The setup reproduces staging's statistics: 40 tenants and the measured
  # parent_id ratio, all-visible pages as a vacuumed table's (staging: 577
  # of 607). Not async: ALTER TABLE, CLUSTER and the role drop.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, FolderRows, QueryPlan, QueryRecorder, Repo}
  alias Engram.Folders.Rows

  @big 500
  @small 5

  setup do
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
    QueryPlan.all_visible!(["folders"])

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
    big = Repo.with_tenant!(u.id, fn -> Rows.id_by_walk(u, v.id, "Big") end)
    # A live row the path-hash read misses (no `full_path_hmac`), so the
    # insert conflicts and `ensure_all` reads it by `(parent, name)`.
    orphan = FolderRows.insert!(u, v, Rows.name_hmac(fk, "Orphan"), parent: big)

    plans =
      plans(
        u,
        fn ->
          assert {:ok, %{"Big/Orphan" => ^orphan}} = Rows.ensure_all(u, v.id, ["Big/Orphan"])
        end,
        ~r/^SELECT f0\."id" FROM "folders" AS f0 WHERE .*"name_hmac" = .*"parent_id" = /
      )

    for plan <- [plans.custom, plans.generic] do
      assert_name_in_index_cond(plan)
      assert QueryPlan.buffers(plan) <= 6, plan
    end
  end
end
