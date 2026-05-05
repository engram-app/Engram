defmodule EngramWeb.EndpointConfigTest do
  use ExUnit.Case, async: true

  test "websocket_check_origin runtime value is valid shape" do
    # In :test/:dev env this key is unset — false is the default, which is fine.
    # In :prod env (at startup) runtime.exs sets it to a non-empty list.
    # Config is read at request time via the MFA callback in endpoint.ex.
    origin = Application.get_env(:engram, :websocket_check_origin, false)
    assert origin == false or (is_list(origin) and origin != [])
  end

  test "Endpoint.check_origin/1 allows listed origins" do
    Application.put_env(:engram, :websocket_check_origin, [
      "https://app.engram.dev",
      "app://obsidian.md"
    ])

    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    assert EngramWeb.Endpoint.check_origin("https://app.engram.dev")
    assert EngramWeb.Endpoint.check_origin("app://obsidian.md")
    refute EngramWeb.Endpoint.check_origin("https://evil.com")
  end

  test "Endpoint.check_origin/1 allows all when config is false (origin checking disabled)" do
    Application.put_env(:engram, :websocket_check_origin, false)
    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    assert EngramWeb.Endpoint.check_origin("https://anything.example.com")
  end

  # Phoenix.Socket.Transport calls the MFA with `URI.parse(origin)`, not the raw string.
  # Without URI handling, naive `origin in list` against string allowlist always rejects.
  test "Endpoint.check_origin/1 accepts URI struct (Phoenix transport contract)" do
    Application.put_env(:engram, :websocket_check_origin, [
      "http://engram.ax",
      "app://obsidian.md"
    ])

    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    assert EngramWeb.Endpoint.check_origin(URI.parse("app://obsidian.md"))
    assert EngramWeb.Endpoint.check_origin(URI.parse("http://engram.ax"))
    refute EngramWeb.Endpoint.check_origin(URI.parse("https://evil.com"))
  end

  test "Endpoint.check_origin/1 accepts URI struct when checking is disabled" do
    Application.put_env(:engram, :websocket_check_origin, false)
    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    assert EngramWeb.Endpoint.check_origin(URI.parse("https://anything.example.com"))
  end

  # Origin headers can arrive scheme-less ("null", "anonymous", clients sending
  # malformed values). Phoenix calls our MFA with URI.parse(origin) which yields
  # %URI{scheme: nil, ...}. URI.default_port(nil) raises FunctionClauseError —
  # without a guard, every such request crashes the WS transport and floods logs.
  test "Endpoint.check_origin/1 rejects URI with nil scheme without crashing" do
    Application.put_env(:engram, :websocket_check_origin, [
      "http://engram.ax",
      "app://obsidian.md"
    ])

    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    refute EngramWeb.Endpoint.check_origin(URI.parse("null"))
    refute EngramWeb.Endpoint.check_origin(%URI{scheme: nil, host: nil, port: nil})
  end

  test "Endpoint.check_origin/1 normalizes URI with explicit non-default port" do
    Application.put_env(:engram, :websocket_check_origin, [
      "http://engram.ax:8080"
    ])

    on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

    assert EngramWeb.Endpoint.check_origin(URI.parse("http://engram.ax:8080"))
    refute EngramWeb.Endpoint.check_origin(URI.parse("http://engram.ax"))
  end

  # Drives Phoenix.Socket.Transport.check_origin/5 — the actual code path that
  # logged the FastRaid production error. This closes the gap that pure unit
  # tests on `EngramWeb.Endpoint.check_origin/1` left open: it proves Phoenix
  # really invokes our MFA with `URI.parse(origin)` and that the fix unblocks
  # the WebSocket handshake for `app://obsidian.md`.
  describe "Phoenix.Socket.Transport.check_origin (integration)" do
    setup do
      Application.put_env(:engram, :websocket_check_origin, [
        "http://engram.ax",
        "app://obsidian.md"
      ])

      # Phoenix.Socket.Transport caches `:check_origin` config per
      # `{handler, endpoint}` in :ets. Use a unique handler module per test so
      # the cache from one test cannot poison another, even with async: false.
      handler =
        Module.concat([__MODULE__, "Handler#{System.unique_integer([:positive])}"])

      Module.create(
        handler,
        quote do
          def __socket__(:user_socket), do: nil
        end,
        Macro.Env.location(__ENV__)
      )

      on_exit(fn -> Application.delete_env(:engram, :websocket_check_origin) end)

      %{handler: handler}
    end

    test "accepts Obsidian app:// origin", %{handler: handler} do
      conn = build_conn_with_origin("app://obsidian.md")

      result =
        Phoenix.Socket.Transport.check_origin(
          conn,
          handler,
          EngramWeb.Endpoint,
          check_origin: {EngramWeb.Endpoint, :check_origin, []}
        )

      refute result.halted, "Phoenix should accept allowlisted Obsidian origin"
    end

    test "accepts configured web host origin", %{handler: handler} do
      conn = build_conn_with_origin("http://engram.ax")

      result =
        Phoenix.Socket.Transport.check_origin(
          conn,
          handler,
          EngramWeb.Endpoint,
          check_origin: {EngramWeb.Endpoint, :check_origin, []}
        )

      refute result.halted
    end

    test "rejects an origin that is not in the allowlist", %{handler: handler} do
      conn = build_conn_with_origin("https://evil.example.com")

      # `sender` (5th arg) is invoked instead of the default `Plug.Conn.send_resp/1`
      # so the rejection conn is captured rather than actually transmitted.
      # Phoenix logs the same "Could not check origin" error we saw in production
      # — capture it to keep test output clean while still asserting on it.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            Phoenix.Socket.Transport.check_origin(
              conn,
              handler,
              EngramWeb.Endpoint,
              [check_origin: {EngramWeb.Endpoint, :check_origin, []}],
              fn captured -> captured end
            )

          assert result.halted
          assert result.status == 403
        end)

      assert log =~ "Could not check origin for Phoenix.Socket transport"
      assert log =~ "https://evil.example.com"
    end

    defp build_conn_with_origin(origin) do
      Plug.Test.conn(:get, "/socket/websocket")
      |> Plug.Conn.put_req_header("origin", origin)
    end
  end
end
