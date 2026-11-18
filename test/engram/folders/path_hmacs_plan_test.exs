defmodule Engram.Folders.PathHmacsPlanTest do
  @moduledoc """
  `Engram.Folders.PathHmacs`, the one writer of `folders.full_path_hmac`,
  planned as `engram_app` under FORCE RLS (custom and generic plans), at
  the polluted-statistics shape the chain-read plan tests use (40 tenants,
  so a probe keyed only by the tenant InitPlan ties with a tenant scan).
  Each statement must find the rows it writes by primary key and the hash's
  other holders through `folders_full_path` (vault_id, full_path_hmac):
  never a sequential scan, never a read of the tenant's folders.
  """
  # Not async: alters column statistics.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, QueryPlan, QueryRecorder, Repo}
  alias Engram.Folders.{PathHmacs, Rows}

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    {:ok, fk} = Crypto.dek_filter_key(user)

    # The 40-tenant shape, laid out as prod is: 40 tenants' folders
    # interleaved on the heap (30 rounds, one row per tenant each), so the
    # tenant index has no physical correlation to make a tenant scan cheap.
    others =
      for _ <- 1..39 do
        other = insert(:user)
        {other, insert(:vault, user: other)}
      end

    for i <- 1..30, {o, ov} <- [{user, vault} | others] do
      Engram.FolderRows.insert!(o, ov, Rows.name_hmac(fk, "R#{i}"),
        full_path_hmac: Rows.path_hmac(fk, "R#{i}")
      )
    end

    {:ok, _} = Repo.with_tenant(user.id, fn -> Rows.ensure_all(user, vault.id, ["A/S1"]) end)

    Repo.query!("ALTER TABLE folders ALTER COLUMN vault_id SET (n_distinct = 40)")
    Repo.query!("ALTER TABLE folders ALTER COLUMN user_id SET (n_distinct = 40)")
    QueryPlan.fresh!("folders")

    %{user: user, vault: vault, fk: fk}
  end

  defp tenant!(user, fun) do
    {:ok, result} = Repo.with_tenant(user.id, fun)
    result
  end

  defp recorded(user, fun) do
    {_, queries} = QueryRecorder.record(fn -> tenant!(user, fun) end)
    me = self()

    [{sql, params}] =
      for %{sql: s, params: p, pid: ^me} <- queries, s =~ "full_path_hmac", do: {s, p}

    {sql, params}
  end

  # No sequential scan and no tenant-wide read: every `folders` scan is an
  # index probe whose condition names the row (`id`) or the hash.
  defp assert_keyed!(plan) do
    refute plan =~ "Seq Scan", plan
    refute plan =~ "folders_user", plan

    conds =
      plan
      |> String.split("\n")
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [scan, _] -> scan =~ ~r/Index (Only )?Scan using \w+ on folders/ end)

    assert conds != [], plan

    for [scan, cond] <- conds,
        do: assert(cond =~ ~r/Index Cond: .*(\bid = |full_path_hmac = )/, scan <> "\n" <> plan)
  end

  test "put: the writes by primary key, the release through folders_full_path", ctx do
    %{user: u, vault: v, fk: fk} = ctx
    [a, s1] = tenant!(u, fn -> Rows.ids_at(u, v.id, ["A", "A/S1"]) end)

    {sql, params} =
      recorded(u, fn ->
        PathHmacs.put(u.id, [{a, Rows.path_hmac(fk, "Z")}, {s1, Rows.path_hmac(fk, "Z/S1")}])
      end)

    plans = QueryPlan.rls_plans(u.id, sql, params)

    for plan <- [plans.custom, plans.generic] do
      assert_keyed!(plan)
      assert plan =~ "folders_full_path", plan
      # Two targets and their holders: a handful of pages, not the tenant's.
      assert QueryPlan.buffers(plan) <= 40, plan
    end
  end

  test "yield: by primary key, the other holder through folders_full_path", ctx do
    %{user: u, vault: v} = ctx
    ids = tenant!(u, fn -> Rows.ids_at(u, v.id, ["R1", "R2"]) end)

    {sql, params} = recorded(u, fn -> PathHmacs.yield(v.id, ids) end)
    plans = QueryPlan.rls_plans(u.id, sql, params)

    for plan <- [plans.custom, plans.generic] do
      assert_keyed!(plan)
      assert plan =~ "folders_full_path", plan
      assert QueryPlan.buffers(plan) <= 30, plan
    end
  end

  # The restore's read of each revived row's current path
  # (`Rows.paths_by_ids/4`, a chain walk up from each id).
  test "the restore's path read walks by id", %{user: u, vault: v} do
    ids = tenant!(u, fn -> Rows.ids_at(u, v.id, ["A", "A/S1"]) end)
    {:ok, dek} = Crypto.get_dek(u)

    {_, queries} =
      QueryRecorder.record(fn -> tenant!(u, fn -> Rows.paths_by_ids(dek, v.id, ids) end) end)

    me = self()
    [{sql, params}] = for %{sql: s, params: p, pid: ^me} <- queries, s =~ "folders", do: {s, p}
    plans = QueryPlan.rls_plans(u.id, sql, params)

    for plan <- [plans.custom, plans.generic] do
      assert_keyed!(plan)
      assert QueryPlan.buffers(plan) <= 30, plan
    end
  end
end
