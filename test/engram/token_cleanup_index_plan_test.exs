defmodule Engram.TokenCleanupIndexPlanTest do
  # Guard: the 15-minute token cleanups find their rows through the partial
  # indexes added for them, rather than seq-scanning both token tables.
  use Engram.DataCase, async: true

  alias Engram.Auth.DeviceFlow
  alias Engram.OAuth
  alias Engram.QueryPlan
  alias Engram.QueryRecorder

  defp plans(fun, table) do
    {_, queries} = QueryRecorder.record(fun)

    for %{sql: sql} <- queries,
        sql =~ ~s("#{table}"),
        not String.starts_with?(sql, "SELECT pg_"),
        do: {sql, QueryPlan.generic_plan(sql)}
  end

  test "device token cleanup uses the revoked and the unrevoked-expiry indexes" do
    plans = plans(&DeviceFlow.cleanup_expired/0, "device_refresh_tokens")
    text = Enum.map_join(plans, "\n----\n", fn {sql, plan} -> sql <> "\n" <> plan end)

    assert text =~ "device_refresh_tokens_revoked_at_index", text
    assert text =~ "device_refresh_tokens_unrevoked_expires_at_index", text
  end

  test "the OAuth reap finds revoked families through the revoked_at index" do
    client = insert(:oauth_client)
    user = insert(:user)
    long_ago = DateTime.add(DateTime.utc_now(:second), -8 * 24 * 3600, :second)

    insert(:oauth_refresh_token,
      user_id: user.id,
      client_id: client.client_id,
      revoked_at: long_ago
    )

    plans = plans(&OAuth.cleanup_expired/0, "oauth_refresh_tokens")

    reap =
      for {sql, plan} <- plans, sql =~ "SELECT DISTINCT", sql =~ "family_id\" IN", do: plan

    assert [plan | _] = reap
    assert plan =~ "oauth_refresh_tokens_revoked_at_index", plan
  end
end
