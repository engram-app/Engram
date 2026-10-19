defmodule EngramWeb.LogsDeviceBudgetTest do
  # async: false: reset_buckets!/0 wipes the node-global limiter table and
  # aligns the burst to a fresh window, so a burst never straddles an edge.
  use EngramWeb.ConnCase, async: false
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Engram.Logs.ClientLog
  alias Engram.Repo

  @budget 5_000

  setup %{conn: conn} do
    EngramWeb.RateLimiter.reset_buckets!()
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)
    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user}
  end

  defp lines(n), do: for(i <- 1..n//1, do: %{level: "info", category: "t", message: "m#{i}"})

  defp send_logs(conn, n, device \\ nil) do
    conn = if device, do: put_req_header(conn, "x-device-id", device), else: conn
    conn |> post("/api/logs", %{logs: lines(n)}) |> json_response(200)
  end

  # Spend the whole budget in max-size batches (the per-request cap is 1,000).
  defp exhaust(conn, device \\ nil),
    do:
      for(
        _ <- 1..div(@budget, 1000),
        do: assert(%{"count" => 1000} = send_logs(conn, 1000, device))
      )

  defp stored(user),
    do:
      Repo.aggregate(from(l in ClientLog, where: l.user_id == ^user.id), :count,
        skip_tenant_check: true
      )

  test "a device may spend exactly its budget; the next line is dropped with 200", %{
    conn: conn,
    user: user
  } do
    exhaust(conn, "dev-a")

    log =
      capture_log(fn -> assert %{"ok" => true, "count" => 0} = send_logs(conn, 1, "dev-a") end)

    assert log =~ "client log budget exceeded"
    assert log =~ "dropped 1"
    assert stored(user) == @budget
  end

  test "a batch that would cross the budget is dropped whole", %{conn: conn, user: user} do
    for _ <- 1..div(@budget, 1000), do: send_logs(conn, 999, "dev-a")
    remaining = @budget - 999 * div(@budget, 1000)
    assert %{"count" => 0} = send_logs(conn, remaining + 1, "dev-a")
    assert %{"count" => 0} = send_logs(conn, 1, "dev-a")
    assert stored(user) == 999 * div(@budget, 1000)
  end

  test "budgets are per device", %{conn: conn, user: user} do
    exhaust(conn, "dev-a")
    assert %{"count" => 0} = send_logs(conn, 1, "dev-a")
    assert %{"count" => 1} = send_logs(conn, 1, "dev-b")
    assert stored(user) == @budget + 1
  end

  test "without X-Device-Id the user shares one fallback budget", %{conn: conn} do
    exhaust(conn)
    assert %{"count" => 0} = send_logs(conn, 1)
    # A named device does not draw on the fallback bucket.
    assert %{"count" => 1} = send_logs(conn, 1, "dev-a")
  end

  test "empty batches never spend the budget", %{conn: conn} do
    for _ <- 1..3, do: assert(%{"count" => 0} = send_logs(conn, 0, "dev-a"))
    exhaust(conn, "dev-a")
    assert %{"count" => 0} = send_logs(conn, 1, "dev-a")
  end

  test "a batch that exactly fills the remaining budget is accepted", %{conn: conn} do
    for _ <- 1..div(@budget, 1000), do: send_logs(conn, 999, "dev-a")
    remaining = @budget - 999 * div(@budget, 1000)
    assert %{"count" => ^remaining} = send_logs(conn, remaining, "dev-a")
    assert %{"count" => 0} = send_logs(conn, 1, "dev-a")
  end

  # X-Device-Id is client-chosen: rotating it per request must not mint a fresh
  # budget each time. The per-user total is 4 devices' worth.
  test "rotating device ids cannot exceed the per-user total", %{conn: conn, user: user} do
    for d <- 1..4, do: exhaust(conn, "dev-#{d}")
    assert %{"count" => 0} = send_logs(conn, 1, "dev-5")
    assert stored(user) == 4 * @budget
  end

  # The e2e harness keeps one device id for the whole run and its log oracle
  # reads these lines, so CI must be able to lift the budget.
  test "the budget honours the CI override", %{conn: conn} do
    Application.put_env(:engram, :client_log_line_budget_override, 10)
    on_exit(fn -> Application.delete_env(:engram, :client_log_line_budget_override) end)

    assert %{"count" => 10} = send_logs(conn, 10, "dev-a")
    assert %{"count" => 0} = send_logs(conn, 1, "dev-a")
  end
end
