defmodule EngramWeb.McpVersionNegotiationTest do
  @moduledoc """
  `initialize` used to discard the client's requested version and answer a
  hardcoded `2025-03-26` — the revision that predates structured tool output,
  so `outputSchema` / `structuredContent` were unreadable by any client that
  honoured what we announced.

  A bare version bump would have been the wrong fix: it forces every client
  onto a newer revision whether it asked or not. The lifecycle spec says a
  server MUST echo the requested version when it supports it, and otherwise
  SHOULD answer with the latest it does support.
  """
  use EngramWeb.ConnCase, async: true

  alias EngramWeb.McpController

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}")}
  end

  defp initialize(conn, params) do
    conn
    |> post("/api/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => params
    })
    |> json_response(200)
    |> get_in(["result", "protocolVersion"])
  end

  describe "negotiation" do
    test "echoes a supported version the client asked for", %{conn: conn} do
      for version <- McpController.legacy_protocol_versions() do
        assert initialize(conn, %{"protocolVersion" => version}) == version
      end
    end

    test "structured output is reachable: 2025-06-18 is supported" do
      # outputSchema / structuredContent landed in this revision. Announcing an
      # older one makes the whole feature dead weight for a conformant client.
      assert "2025-06-18" in McpController.legacy_protocol_versions()
    end

    test "answers the newest supported version when the client asks for one we lack", %{
      conn: conn
    } do
      newest = List.first(McpController.legacy_protocol_versions())

      assert initialize(conn, %{"protocolVersion" => "2099-01-01"}) == newest
      assert initialize(conn, %{"protocolVersion" => "gibberish"}) == newest
    end

    test "a client that names no version gets 2025-03-26, unchanged from before", %{conn: conn} do
      # Pinned, not derived from the list: adding an OLDER revision for
      # compatibility must not drag the versionless answer down with it.
      assert initialize(conn, %{}) == "2025-03-26"
    end

    test "2024-11-05 is still negotiable, so pre-June-2025 SDKs keep connecting" do
      # Those SDKs ship SUPPORTED_PROTOCOL_VERSIONS = ["2025-03-26",
      # "2024-11-05"] and ABORT on anything else. Dropping it from the surface
      # meant they asked for 2024-11-05, were answered 2025-06-18, and stopped
      # connecting — broken by an upgrade they never requested.
      assert "2024-11-05" in McpController.legacy_protocol_versions()
    end

    test "a legacy client is echoed its own version, not upgraded", %{conn: conn} do
      assert initialize(conn, %{"protocolVersion" => "2024-11-05"}) == "2024-11-05"
    end

    test "array-form params do not crash the handshake", %{conn: conn} do
      # JSON-RPC 2.0 allows them, and `[]` is truthy so it reaches dispatch
      # intact. Access raises on a non-keyword list.
      body =
        conn
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => []
        })
        |> json_response(200)

      assert body["result"]["protocolVersion"] == "2025-03-26"
    end

    test "a struct in place of params does not crash the handshake" do
      # The endpoint parses multipart with `pass: ["*/*"]`, so a file field
      # named `params` lands a %Plug.Upload{} — which matches %{} but has no
      # Access implementation.
      upload = %Plug.Upload{path: "/tmp/x", filename: "x", content_type: "text/plain"}

      assert McpController.handshake_metadata(upload)[:mcp_protocol_served] == "2025-03-26"
    end

    test "a non-string version does not crash the handshake", %{conn: conn} do
      newest = List.first(McpController.legacy_protocol_versions())

      assert initialize(conn, %{"protocolVersion" => 20_250_618}) == newest
      assert initialize(conn, %{"protocolVersion" => %{"a" => 1}}) == newest
    end

    test "the version list is newest-first and has no duplicates" do
      versions = McpController.legacy_protocol_versions()

      assert versions == versions |> Enum.uniq() |> Enum.sort(:desc)
    end
  end

  describe "the handshake log records both sides" do
    test "served reflects what was negotiated, not a constant" do
      meta = McpController.handshake_metadata(%{"protocolVersion" => "2025-06-18"})

      assert meta[:mcp_protocol_requested] == "2025-06-18"
      assert meta[:mcp_protocol_served] == "2025-06-18"
    end

    test "a downgrade is visible in the log line" do
      meta = McpController.handshake_metadata(%{"protocolVersion" => "2099-01-01"})

      assert meta[:mcp_protocol_requested] == "2099-01-01"
      assert meta[:mcp_protocol_served] == List.first(McpController.legacy_protocol_versions())
    end
  end

  describe "MCP-Protocol-Version header" do
    # Required on subsequent HTTP requests from 2025-06-18. We do not enforce a
    # match (that would break clients mid-migration), but an unsupported value
    # must not be silently treated as supported.
    test "a supported header value is accepted", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert json_response(conn, 200)["result"]["tools"]
    end

    test "an absent header still works, for pre-2025-06-18 clients", %{conn: conn} do
      conn = post(conn, "/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert json_response(conn, 200)["result"]["tools"]
    end

    test "an invalid-UTF-8 header value still yields 400, not a 500", %{conn: conn} do
      # Raw header bytes are not JSON-decoded values: echoing them into the
      # error body raised Jason.EncodeError while rendering the refusal.
      conn =
        conn
        |> put_req_header("mcp-protocol-version", <<0xFF, 0xFE, 0x41>>)
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert json_response(conn, 400)["error"]["message"] =~ "protocol version"
    end

    test "an oversized header value is not echoed back verbatim", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-protocol-version", String.duplicate("v", 4_000))
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      body = json_response(conn, 400)

      assert byte_size(body["error"]["message"]) < 500
    end

    test "a non-encodable id does not turn the 400 into a 500", %{conn: conn} do
      # The endpoint parses multipart with `pass: ["*/*"]`, so a form part named
      # `id` WITH a filename arrives as a %Plug.Upload{}. It is a map, so no
      # container guard catches it, and it has no Jason.Encoder — echoing it
      # into the error body raised Protocol.UndefinedError. A 500 here pages:
      # it feeds HTTPCode_Target_5XX_Count and fires Sentry.
      upload = %Plug.Upload{path: "/tmp/x", filename: "x", content_type: "text/plain"}

      conn =
        conn
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => upload, "method" => "tools/list"})

      body = json_response(conn, 400)

      assert body["id"] == nil
      assert body["error"]["message"] =~ "protocol version"
    end

    test "a legal id is still echoed", %{conn: conn} do
      for id <- [7, "abc"] do
        conn =
          conn
          |> put_req_header("mcp-protocol-version", "1999-01-01")
          |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list"})

        assert json_response(conn, 400)["id"] == id
      end
    end

    test "an unsupported header value is refused rather than ignored", %{conn: conn} do
      conn =
        conn
        |> put_req_header("mcp-protocol-version", "1999-01-01")
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      body = json_response(conn, 400)

      assert body["error"]["message"] =~ "protocol version"
    end
  end
end
