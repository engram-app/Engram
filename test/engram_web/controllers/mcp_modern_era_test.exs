defmodule EngramWeb.McpModernEraTest do
  @moduledoc """
  #1659 slice 1: the `2026-07-28` era.

  That revision DELETES the handshake. There is no `initialize`; every request
  carries its own protocol version and client capabilities in `_meta`, and the
  server accepts or rejects each request independently. So this is not a
  version bump — it is a second protocol era beside the legacy one, which the
  spec explicitly permits ("A dual-era server MAY serve both eras concurrently
  on the same endpoint").

  The legacy path must stay byte-for-byte unchanged, which is what makes
  building this forward safe with no traffic to test against.
  """
  use EngramWeb.ConnCase, async: true

  alias EngramWeb.McpController

  @modern "2026-07-28"
  @meta_version "io.modelcontextprotocol/protocolVersion"
  @meta_caps "io.modelcontextprotocol/clientCapabilities"
  @meta_client "io.modelcontextprotocol/clientInfo"
  @meta_server "io.modelcontextprotocol/serverInfo"

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), vault: vault}
  end

  defp modern_meta(overrides \\ %{}) do
    Map.merge(
      %{
        @meta_version => @modern,
        @meta_caps => %{},
        @meta_client => %{"name" => "test", "version" => "1"}
      },
      overrides
    )
  end

  defp post_modern(conn, method, params \\ %{}, meta \\ nil) do
    conn
    |> put_req_header("mcp-protocol-version", @modern)
    |> post("/api/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta || modern_meta())
    })
  end

  describe "server/discover" do
    test "servers MUST implement it", %{conn: conn} do
      result = json_response(post_modern(conn, "server/discover"), 200)["result"]

      assert result["resultType"] == "complete"
      assert @modern in result["supportedVersions"]
      assert is_map(result["capabilities"])
      assert result["_meta"][@meta_server]["name"] == "engram"
    end

    test "advertises every revision we serve, newest first", %{conn: conn} do
      result = json_response(post_modern(conn, "server/discover"), 200)["result"]

      assert result["supportedVersions"] == McpController.supported_protocol_versions()
      assert List.first(result["supportedVersions"]) == @modern
    end
  end

  describe "modern results" do
    test "every result carries resultType", %{conn: conn} do
      result = json_response(post_modern(conn, "tools/list"), 200)["result"]

      assert result["resultType"] == "complete"
      assert length(result["tools"]) == 21
    end

    test "and serverInfo in _meta", %{conn: conn} do
      result = json_response(post_modern(conn, "tools/list"), 200)["result"]

      assert result["_meta"][@meta_server]["name"] == "engram"
    end

    test "the legacy era gets neither", %{conn: conn} do
      result =
        conn
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
        |> json_response(200)
        |> Map.fetch!("result")

      refute Map.has_key?(result, "resultType")
      refute Map.has_key?(result, "_meta")
    end
  end

  describe "per-request _meta validation" do
    test "a missing protocolVersion is -32602 on HTTP 400", %{conn: conn} do
      meta = Map.delete(modern_meta(), @meta_version)

      # Only reachable via the header, since _meta is what usually marks the
      # era. The header says modern, so the request is judged as modern.
      resp = json_response(post_modern(conn, "tools/list", %{}, meta), 400)

      assert resp["error"]["code"] == -32_602
    end

    test "a missing clientCapabilities is -32602 on HTTP 400", %{conn: conn} do
      meta = Map.delete(modern_meta(), @meta_caps)

      assert json_response(post_modern(conn, "tools/list", %{}, meta), 400)["error"]["code"] ==
               -32_602
    end
  end

  describe "version errors" do
    test "an unsupported version is -32022 naming what we support", %{conn: conn} do
      meta = modern_meta(%{@meta_version => "1900-01-01"})

      resp =
        conn
        |> put_req_header("mcp-protocol-version", "1900-01-01")
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{"_meta" => meta}
        })
        |> json_response(400)

      assert resp["error"]["code"] == -32_022

      # MUST list what we do support, so the client can retry rather than give
      # up. Was a bare -32600 with the versions only in the prose message.
      supported = resp["error"]["data"]["supported"]
      assert is_list(supported) and supported != []
      assert Enum.all?(supported, &is_binary/1)
      assert resp["error"]["data"]["requested"] == "1900-01-01"
    end
  end

  describe "header / _meta agreement" do
    test "a header disagreeing with the envelope is -32020", %{conn: conn} do
      resp =
        conn
        |> put_req_header("mcp-protocol-version", @modern)
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{"_meta" => modern_meta(%{@meta_version => "2025-06-18"})}
        })
        |> json_response(400)

      assert resp["error"]["code"] == -32_020
    end
  end

  describe "methods the 2026 revision removed" do
    for method <- ["initialize", "ping", "logging/setLevel"] do
      test "#{method} answers 404 with -32601", %{conn: conn} do
        resp = post_modern(conn, unquote(method))

        assert resp.status == 404
        assert json_response(resp, 404)["error"]["code"] == -32_601
      end
    end

    test "but ping still works in the legacy era", %{conn: conn} do
      assert %{"result" => %{}} =
               conn
               |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
               |> json_response(200)
    end
  end

  describe "unknown methods" do
    test "are -32601, not -32600", %{conn: conn} do
      assert json_response(post_modern(conn, "nope/nope"), 404)["error"]["code"] == -32_601
    end
  end

  describe "tools still work in the modern era" do
    test "tools/call returns structuredContent and a resultType", %{conn: conn} do
      result =
        post_modern(conn, "tools/call", %{"name" => "list_vaults", "arguments" => %{}})
        |> json_response(200)
        |> Map.fetch!("result")

      assert result["resultType"] == "complete"
      assert is_map(result["structuredContent"])
      assert [%{"name" => "Test Vault"}] = result["structuredContent"]["vaults"]
    end
  end
end
