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
      assert length(result["tools"]) == 16
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

  describe "cache hints on cacheable results" do
    # Servers MUST include them on `resultType: "complete"` results from
    # server/discover, tools/list, prompts/list, resources/list,
    # resources/templates/list and resources/read. We expose the first two.
    for method <- ["server/discover", "tools/list"] do
      test "#{method} carries ttlMs and cacheScope", %{conn: conn} do
        result = json_response(post_modern(conn, unquote(method)), 200)["result"]

        assert is_integer(result["ttlMs"])
        assert result["ttlMs"] >= 0, "servers MUST provide ttlMs >= 0"
        assert result["cacheScope"] in ["public", "private"]
      end
    end

    test "tools/list is public because the list is identical for every caller", %{conn: conn} do
      result = json_response(post_modern(conn, "tools/list"), 200)["result"]

      assert result["cacheScope"] == "public"
    end

    test "a tools/call result carries no cache hints", %{conn: conn} do
      # Not on the cacheable list, and its result depends on the caller's data.
      result =
        post_modern(conn, "tools/call", %{"name" => "list_vaults", "arguments" => %{}})
        |> json_response(200)
        |> Map.fetch!("result")

      refute Map.has_key?(result, "ttlMs")
      refute Map.has_key?(result, "cacheScope")
    end

    test "the legacy era gets no cache hints", %{conn: conn} do
      result =
        conn
        |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
        |> json_response(200)
        |> Map.fetch!("result")

      refute Map.has_key?(result, "ttlMs")
    end
  end

  describe "Mcp-Method header" do
    test "agreeing with the body is fine", %{conn: conn} do
      resp =
        conn
        |> put_req_header("mcp-protocol-version", @modern)
        |> put_req_header("mcp-method", "tools/list")
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{"_meta" => modern_meta()}
        })

      assert json_response(resp, 200)["result"]["resultType"] == "complete"
    end

    test "disagreeing with the body is -32020 on HTTP 400", %{conn: conn} do
      resp =
        conn
        |> put_req_header("mcp-protocol-version", @modern)
        |> put_req_header("mcp-method", "tools/call")
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{"_meta" => modern_meta()}
        })
        |> json_response(400)

      assert resp["error"]["code"] == -32_020
    end

    test "an invalid-UTF-8 Mcp-Method header does not crash", %{conn: conn} do
      resp =
        conn
        |> put_req_header("mcp-protocol-version", @modern)
        |> put_req_header("mcp-method", <<0xFF, 0xFE>>)
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{"_meta" => modern_meta()}
        })

      assert resp.status == 400
      assert json_response(resp, 400)["error"]["code"] == -32_020
    end
  end

  describe "notifications never get a response" do
    test "a removed method sent as a NOTIFICATION is acknowledged, not answered", %{conn: conn} do
      # JSON-RPC: "The receiver MUST NOT send a response" to a notification,
      # and MCP adds "the ID MUST NOT be null". The removed-methods clause
      # matched on method alone, so it answered a notification with a 404 whose
      # body carried `"id": null` — two MUSTs broken, and nothing the sender
      # could act on since it was not waiting for a reply.
      resp =
        conn
        |> put_req_header("mcp-protocol-version", @modern)
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "method" => "notifications/roots/list_changed",
          "params" => %{"_meta" => modern_meta()}
        })

      assert resp.status == 202
      assert resp.resp_body == ""
    end

    test "a removed method sent as a REQUEST still 404s", %{conn: conn} do
      resp = post_modern(conn, "ping")

      assert resp.status == 404
      assert json_response(resp, 404)["error"]["code"] == -32_601
    end

    test "an ordinary notification is still acknowledged", %{conn: conn} do
      resp =
        conn
        |> put_req_header("mcp-protocol-version", @modern)
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized",
          "params" => %{"_meta" => modern_meta()}
        })

      assert resp.status == 202
    end
  end

  describe "the declared version picks the era, not the shape of _meta" do
    test "modern _meta declaring a legacy revision gets a legacy-shaped result", %{conn: conn} do
      # A client can carry modern per-request metadata while asking for a
      # revision that has no resultType and no caching model. Serving it a
      # modern shape answers in a dialect it did not ask for; the extra keys
      # are ignorable, but the era is the client's to declare.
      result =
        conn
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{
            "_meta" => %{
              @meta_version => "2025-06-18",
              @meta_caps => %{}
            }
          }
        })
        |> json_response(200)
        |> Map.fetch!("result")

      refute Map.has_key?(result, "resultType")
      refute Map.has_key?(result, "ttlMs")
      assert length(result["tools"]) == 16
    end

    test "a legacy-declared request is not held to modern _meta requirements", %{conn: conn} do
      # `clientCapabilities` is REQUIRED only in the modern era. A client that
      # names 2025-06-18 and omits it is well-formed for the revision it asked
      # for, so deciding the era AFTER validating modern `_meta` rejected a
      # valid legacy request with -32602.
      result =
        conn
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{"_meta" => %{@meta_version => "2025-06-18"}}
        })
        |> json_response(200)
        |> Map.fetch!("result")

      assert length(result["tools"]) == 16
      refute Map.has_key?(result, "resultType")
    end

    test "an unsupported version is still -32022 even though it is not modern", %{conn: conn} do
      # The era check must not swallow this: a client declaring a version we
      # do not implement needs the list of what we do, whichever era it is.
      resp =
        conn
        |> post("/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{"_meta" => %{@meta_version => "1900-01-01", @meta_caps => %{}}}
        })
        |> json_response(400)

      assert resp["error"]["code"] == -32_022
      assert resp["error"]["data"]["supported"] != []
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
