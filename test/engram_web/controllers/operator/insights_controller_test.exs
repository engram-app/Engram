defmodule EngramWeb.Operator.InsightsControllerTest do
  use EngramWeb.ConnCase, async: true

  defp operator, do: insert(:user, role: "operator")

  test "an operator's session reads every report", %{conn: conn} do
    conn = authenticate(conn, operator())

    assert %{"reports" => reports} = conn |> get("/api/operator/insights") |> json_response(200)
    assert "funnel" in reports

    for name <- reports do
      assert %{} = conn |> get("/api/operator/insights/#{name}") |> json_response(200)
    end
  end

  test "?days= bounds a report's window", %{conn: conn} do
    insert(:user, created_at: DateTime.add(DateTime.utc_now(:second), -20, :day))
    conn = authenticate(conn, operator())

    signed_up = fn query ->
      conn
      |> get("/api/operator/insights/funnel#{query}")
      |> json_response(200)
      |> Map.fetch!("steps")
      |> Enum.find(&(&1["step"] == "signed_up"))
      |> Map.fetch!("users")
    end

    assert signed_up.("") == 1
    assert signed_up.("?days=10") == 0
    assert signed_up.("?days=30") == 1
    assert signed_up.("?days=junk") == 1
  end

  test "an operator reads one account's timeline by id", %{conn: conn} do
    user = insert(:user)
    conn = authenticate(conn, operator())

    assert %{"user_id" => id, "events" => []} =
             conn |> get("/api/operator/insights/users/#{user.id}") |> json_response(200)

    assert id == user.id
    assert conn |> get("/api/operator/insights/users/not-a-uuid") |> json_response(404)
    assert conn |> get("/api/operator/insights/nope") |> json_response(404)
  end

  test "404 for a member, and an admin", %{conn: conn} do
    for role <- ["member", "admin"] do
      conn = authenticate(conn, insert(:user, role: role))
      assert conn |> get("/api/operator/insights/funnel") |> json_response(404)
      assert conn |> get("/api/operator/insights") |> json_response(404)
    end
  end

  test "404 for an operator's API key", %{conn: conn} do
    op = operator()
    {:ok, key, _} = Engram.Accounts.create_api_key(op, "k")
    lift_api_rps_cap!(op)

    conn = put_req_header(conn, "authorization", "Bearer #{key}")
    assert conn |> get("/api/operator/insights/funnel") |> json_response(404)
  end

  test "read-only: no write verb is routed", %{conn: conn} do
    conn = authenticate(conn, operator())

    for verb <- [:post, :patch, :put, :delete] do
      assert conn |> dispatch(@endpoint, verb, "/api/operator/insights/funnel") |> response(404)
    end
  end
end
