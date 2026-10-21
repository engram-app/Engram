defmodule EngramWeb.Plugs.RequireOperatorTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.Accounts.User
  alias EngramWeb.Plugs.RequireOperator

  @operator %User{role: "operator", suspended_at: nil, deleted_at: nil}

  defp call(conn), do: RequireOperator.call(conn, [])
  defp as(conn, user), do: assign(conn, :current_user, user)

  test "lets an operator's browser session through", %{conn: conn} do
    refute conn |> as(@operator) |> call() |> Map.get(:halted)
  end

  for role <- ["member", "admin"] do
    test "404 for a #{role}", %{conn: conn} do
      conn = conn |> as(%User{role: unquote(role)}) |> call()
      assert conn.halted and conn.status == 404
    end
  end

  test "404 with no user", %{conn: conn} do
    assert call(conn).status == 404
  end

  test "404 for a suspended or deleted operator", %{conn: conn} do
    for user <- [
          %{@operator | suspended_at: DateTime.utc_now()},
          %{@operator | deleted_at: DateTime.utc_now()}
        ] do
      assert conn |> as(user) |> call() |> Map.get(:status) == 404
    end
  end

  # An operator's API key, plugin token or OAuth grant must not inherit the
  # cross-tenant read plane.
  for {name, assigns} <- [
        api_key: [current_api_key: "k"],
        oauth_scope: [oauth_scope: "notes:read"],
        oauth_grant: [oauth_grant_id: "g"],
        device_token: [device_token: true]
      ] do
    test "404 for an operator's #{name}", %{conn: conn} do
      conn =
        Enum.reduce(unquote(assigns), as(conn, @operator), fn {k, v}, c -> assign(c, k, v) end)

      conn = call(conn)
      assert conn.halted and conn.status == 404
    end
  end
end
