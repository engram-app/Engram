defmodule Engram.Billing.PlanCacheTest do
  # async: false — PlanCache lives in node-global :persistent_term, and one
  # test calls the node-wide PlanCache.invalidate_all/0. A cache that is global
  # and globally-invalidated is not isolatable per-test, so concurrent modules
  # can wipe a warmed entry between a test's warm-read and its cached-read
  # assertion (flaky `left: 99, right: 7` at "invalidate/1 reflects a runtime
  # limit change"). This module is green in isolation; running it non-async
  # keeps it that way. ponytail: async:false is the minimal fix; per-test
  # PlanCache isolation would let it go async again.
  use Engram.DataCase, async: false

  alias Engram.Billing
  alias Engram.Billing.LimitKeys
  alias Engram.Billing.Plan
  alias Engram.Billing.PlanCache
  alias Engram.Repo

  setup do
    plan =
      Repo.insert!(%Plan{
        name: "pro_#{System.unique_integer([:positive])}",
        limits: %{"vaults_cap" => 7, "cross_vault_search" => false}
      })

    user = insert(:user) |> Ecto.Changeset.change(plan_id: plan.id) |> Repo.update!()
    on_exit(fn -> PlanCache.invalidate(plan.id) end)
    %{plan: plan, user: user}
  end

  test "resolves plan limits and caches them after the first lookup", %{plan: plan, user: user} do
    PlanCache.invalidate(plan.id)

    {first, q1} =
      with_query_count("plans", fn -> Billing.effective_limit(user, :vaults_cap) end)

    assert first == 7
    assert q1 == 1

    {second, q2} =
      with_query_count("plans", fn -> Billing.effective_limit(user, :vaults_cap) end)

    assert second == 7
    assert q2 == 0
  end

  test "cached lookup preserves false plan values (not treated as missing)", %{user: user} do
    assert Billing.effective_limit(user, :cross_vault_search) == false
    assert Billing.effective_limit(user, :cross_vault_search) == false
  end

  test "missing plan key falls through to the default", %{user: user} do
    # mcp_connections_cap is not set on this plan → default for tier. Chosen
    # because its Free default (1) differs from every value stored on the
    # fixture plan: a key defaulting to `false` would assert `false == false`
    # and still pass if `wrap_lookup(nil)` started returning `{:hit, false}`,
    # which is exactly the miss-vs-stored-false distinction the test above pins.
    assert Billing.effective_limit(user, :mcp_connections_cap) ==
             LimitKeys.default_for(:mcp_connections_cap, :free)

    assert Billing.effective_limit(user, :mcp_connections_cap) == 1
  end

  test "invalidate/1 forces a re-read", %{plan: plan, user: user} do
    Billing.effective_limit(user, :vaults_cap)
    PlanCache.invalidate(plan.id)

    {_, q} = with_query_count("plans", fn -> Billing.effective_limit(user, :vaults_cap) end)
    assert q == 1
  end

  test "invalidate/1 reflects a runtime limit change (not just a re-query)",
       %{plan: plan, user: user} do
    assert Billing.effective_limit(user, :vaults_cap) == 7

    plan |> Ecto.Changeset.change(limits: %{"vaults_cap" => 99}) |> Repo.update!()
    # Still cached → stale value until invalidated.
    assert Billing.effective_limit(user, :vaults_cap) == 7

    PlanCache.invalidate(plan.id)
    assert Billing.effective_limit(user, :vaults_cap) == 99
  end

  test "invalidate_all/0 drops every cached plan", %{plan: plan, user: user} do
    assert Billing.effective_limit(user, :vaults_cap) == 7

    plan |> Ecto.Changeset.change(limits: %{"vaults_cap" => 42}) |> Repo.update!()
    PlanCache.invalidate_all()

    assert Billing.effective_limit(user, :vaults_cap) == 42
  end

  test "an unknown plan id resolves to an empty limits map (falls to defaults)" do
    missing_id = "00000000-0000-0000-0000-000020000000"
    PlanCache.invalidate(missing_id)
    assert PlanCache.limits(missing_id) == %{}
  end

  # Counts Repo queries against `source` emitted while `fun` runs. Telemetry
  # handlers run synchronously in the process that emitted the query, so we
  # scope counting to this test's pid — otherwise concurrent async tests
  # (running in their own processes) leak into the count.
  defp with_query_count(source, fun) do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _event, _measurements, %{source: src}, _config ->
        if src == source and self() == test_pid, do: Agent.update(counter, &(&1 + 1))
      end,
      nil
    )

    try do
      result = fun.()
      {result, Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end
end
