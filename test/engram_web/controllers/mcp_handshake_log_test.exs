defmodule EngramWeb.McpHandshakeLogTest do
  @moduledoc """
  The `initialize` handler discarded its params and unconditionally answered
  `2025-03-26`, so we had no way to tell which protocol era any connected
  client actually asked for — the one fact needed to decide whether the
  2026-07-28 upgrade can drop the legacy path or has to dual-serve it.

  These tests pin the handshake log line that answers it.
  """
  # async: false — the handshake is logged at :info, and the test env runs the
  # Logger at :warning, so the wiring test has to raise the level globally.
  use EngramWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias EngramWeb.McpController

  require Logger

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}")}
  end

  describe "handshake_metadata/1" do
    test "records the version the client asked for and the version we served" do
      meta =
        McpController.handshake_metadata(%{
          "protocolVersion" => "2025-06-18",
          "clientInfo" => %{"name" => "claude-code", "version" => "2.1.0"}
        })

      assert meta[:mcp_protocol_requested] == "2025-06-18"
      assert meta[:mcp_client_name] == "claude-code"
      assert meta[:mcp_client_version] == "2.1.0"
      assert meta[:mcp_protocol_served] == "2025-03-26"
    end

    test "ships to Loki as a lifecycle event" do
      meta = McpController.handshake_metadata(%{})

      assert meta[:category] == :lifecycle
      assert meta[:loki_ship] == true
    end

    test "reports unknown rather than nil when the client omits the fields" do
      meta = McpController.handshake_metadata(%{})

      assert meta[:mcp_protocol_requested] == "unknown"
      assert meta[:mcp_client_name] == "unknown"
      assert meta[:mcp_client_version] == "unknown"
    end

    test "survives array-form params instead of raising on Access" do
      # JSON-RPC 2.0 allows array params, and an empty list is truthy, so it
      # reaches here unchanged from `params["params"] || %{}`.
      meta = McpController.handshake_metadata([])

      assert meta[:mcp_protocol_requested] == "unknown"
      assert meta[:mcp_client_name] == "unknown"
    end

    test "reports unknown when clientInfo is present but not an object" do
      meta = McpController.handshake_metadata(%{"clientInfo" => "claude"})

      assert meta[:mcp_client_name] == "unknown"
      assert meta[:mcp_client_version] == "unknown"
    end

    test "truncates a merely-long string to the grapheme bound" do
      # Between the bound and the byte guard: sliced, not labelled.
      meta =
        McpController.handshake_metadata(%{
          "protocolVersion" => String.duplicate("v", 200),
          "clientInfo" => %{"name" => String.duplicate("n", 200)}
        })

      assert String.length(meta[:mcp_protocol_requested]) == 64
      assert String.length(meta[:mcp_client_name]) == 64
    end

    test "labels a string past the byte guard instead of slicing it" do
      # `String.slice/3` counts graphemes, so slicing alone bounds nothing: a
      # cluster is unbounded in size. Anything past the byte guard is replaced
      # outright rather than cut, since `binary_slice/3` could split a codepoint
      # and hand the JSON formatter invalid UTF-8.
      meta =
        McpController.handshake_metadata(%{
          "protocolVersion" => String.duplicate("v", 500),
          "clientInfo" => %{
            "name" => String.duplicate("n", 500),
            "version" => String.duplicate("x", 500)
          }
        })

      assert meta[:mcp_protocol_requested] == "<oversize>"
      assert meta[:mcp_client_name] == "<oversize>"
      assert meta[:mcp_client_version] == "<oversize>"
    end

    test "coerces non-string client-supplied values instead of crashing" do
      meta =
        McpController.handshake_metadata(%{
          "protocolVersion" => 20_260_728,
          "clientInfo" => %{"name" => %{"nested" => true}, "version" => nil}
        })

      assert is_binary(meta[:mcp_protocol_requested])
      assert is_binary(meta[:mcp_client_name])
      assert meta[:mcp_client_version] == "unknown"
    end
  end

  describe "initialize" do
    setup do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)
      :ok
    end

    test "emits the handshake event carrying what the client asked for", %{conn: conn} do
      log =
        capture_log([metadata: :all], fn ->
          conn =
            post(conn, "/api/mcp", %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "method" => "initialize",
              "params" => %{
                "protocolVersion" => "2025-06-18",
                "clientInfo" => %{"name" => "claude-code", "version" => "2.1.0"}
              }
            })

          assert json_response(conn, 200)["result"]["protocolVersion"] == "2025-03-26"
        end)

      assert log =~ "mcp_handshake"
      assert log =~ "2025-06-18"
      assert log =~ "claude-code"
    end
  end
end
