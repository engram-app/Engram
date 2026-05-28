defmodule EngramWeb.WellKnownHostTest do
  # async: false — these mutate the global :cors_origin app env.
  use EngramWeb.ConnCase, async: false

  setup do
    prev = Application.get_env(:engram, :cors_origin)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:engram, :cors_origin, prev),
        else: Application.delete_env(:engram, :cors_origin)
    end)

    :ok
  end

  describe "multi-domain host derivation" do
    test "advertises the dialed host when it is an allowlisted origin", %{conn: conn} do
      Application.put_env(:engram, :cors_origin, [
        "https://app.engram.page",
        "http://app.engram.page"
      ])

      body =
        %{conn | host: "app.engram.page"}
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      assert body["resource"] == "http://app.engram.page/api/mcp"
      assert body["authorization_servers"] == ["http://app.engram.page"]
    end

    test "issuer reflects the dialed allowlisted host", %{conn: conn} do
      Application.put_env(:engram, :cors_origin, ["http://app.engram.page"])

      body =
        %{conn | host: "app.engram.page"}
        |> get("/.well-known/oauth-authorization-server")
        |> json_response(200)

      assert body["issuer"] == "http://app.engram.page"
      assert body["authorization_endpoint"] == "http://app.engram.page/oauth/authorize"
    end

    test "falls back to canonical for a non-allowlisted host (no Host reflection)", %{conn: conn} do
      Application.put_env(:engram, :cors_origin, ["http://app.engram.page"])

      body =
        %{conn | host: "evil.example.com"}
        |> get("/.well-known/oauth-protected-resource")
        |> json_response(200)

      refute body["resource"] =~ "evil.example.com"
      assert String.ends_with?(body["resource"], "/api/mcp")
    end
  end
end
