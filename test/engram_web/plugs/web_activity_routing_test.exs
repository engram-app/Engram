defmodule EngramWeb.Plugs.WebActivityRoutingTest do
  @moduledoc "The plug is only useful if the router really runs it on the SPA's endpoints."
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    bypass = Bypass.open()

    prior =
      {Application.get_env(:engram, :posthog_key), Application.get_env(:engram, :posthog_host)}

    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      {key, host} = prior
      Application.put_env(:engram, :posthog_key, key)
      Application.put_env(:engram, :posthog_host, host)
    end)

    parent = self()

    Bypass.stub(bypass, "POST", "/capture/", fn c ->
      {:ok, body, c} = Plug.Conn.read_body(c)
      send(parent, {:posthog_body, Jason.decode!(body)})
      Plug.Conn.resp(c, 200, "1")
    end)

    {:ok, _} = Accounts.create_user_with_password("bootstrap-admin@example.com", "password123")
    {:ok, user} = Accounts.create_user_with_password("web@example.com", "password123")
    {:ok, user: user}
  end

  defp events(acc \\ []) do
    receive do
      {:posthog_body, b} -> events([b | acc])
    after
      400 -> acc
    end
  end

  test "GET /api/me with a session JWT emits web surface_active", %{conn: conn, user: user} do
    conn
    |> put_req_header("authorization", "Bearer " <> Accounts.generate_jwt(user))
    |> get("/api/me")

    assert Enum.any?(events(), &(&1["properties"]["surface"] == "web"))
  end

  test "GET /api/me with an API key does not emit web", %{conn: conn, user: user} do
    {:ok, key, _} = Accounts.create_api_key(user, "k")

    conn |> put_req_header("authorization", "Bearer " <> key) |> get("/api/me")

    refute Enum.any?(events(), &(&1["properties"]["surface"] == "web"))
  end
end
