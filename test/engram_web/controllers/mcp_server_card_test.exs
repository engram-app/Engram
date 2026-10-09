defmodule EngramWeb.McpServerCardTest do
  @moduledoc """
  Conformance tests for the MCP Server Card and its AI Catalog entry, per
  `modelcontextprotocol/experimental-ext-server-card` (schema + `docs/discovery.md`
  at upstream commit 526201b, 2026-08-12).

  The schema is vendored at `test/support/fixtures/mcp_server_card.schema.json`.
  To re-sync: fetch `schema.json` from that repo, replace the fixture, and run
  this file. A failure here after a re-sync is the upstream shape moving.
  """
  # async: false — the mcp-host cases mutate global :cors_origin / :host_rewrite.
  use EngramWeb.ConnCase, async: false

  @card_paths ["/.well-known/mcp/server-card.json", "/api/mcp/server-card"]
  @card_type "application/mcp-server-card+json"

  setup_all do
    schema =
      "test/support/fixtures/mcp_server_card.schema.json"
      |> File.read!()
      |> Jason.decode!()
      # Upstream's root holds only `$defs`, so as shipped it accepts ANY value.
      # Point the root at ServerCard; the not-vacuous test below guards this.
      |> Map.put("$ref", "#/$defs/ServerCard")

    # `formats: true` makes `format: uri` an assertion, not a hint.
    {:ok, root: JSV.build!(schema, formats: true)}
  end

  setup do
    prev = Application.get_env(:engram, :cors_origin)
    prev_rewrite = Application.get_env(:engram, :host_rewrite)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:engram, :cors_origin, prev),
        else: Application.delete_env(:engram, :cors_origin)

      if prev_rewrite,
        do: Application.put_env(:engram, :host_rewrite, prev_rewrite),
        else: Application.delete_env(:engram, :host_rewrite)
    end)

    :ok
  end

  defp card(conn, path), do: conn |> get(path) |> Map.fetch!(:resp_body) |> Jason.decode!()

  describe "schema conformance" do
    for path <- @card_paths do
      test "#{path} validates against the upstream v1 schema", %{conn: conn, root: root} do
        assert {:ok, _} = JSV.validate(card(conn, unquote(path)), root)
      end
    end

    test "the validator is not vacuous: a card missing `description` fails", %{
      conn: conn,
      root: root
    } do
      broken = conn |> card("/api/mcp/server-card") |> Map.delete("description")

      assert {:error, _} = JSV.validate(broken, root)
    end

    test "both locations serve the same card", %{conn: conn} do
      [a, b] = Enum.map(@card_paths, &card(conn, &1))
      assert a == b
    end
  end

  describe "card content" do
    test "identity", %{conn: conn} do
      body = card(conn, "/api/mcp/server-card")

      # Same identity the official registry lists (server.json, published by
      # publish-mcp-registry.yml), so directories can join the two.
      assert body["name"] == "server.json" |> File.read!() |> Jason.decode!() |> Map.fetch!("name")
      assert body["version"] == to_string(Application.spec(:engram, :vsn))
      assert body["title"] == "Engram"
      assert body["websiteUrl"] == "https://engram.page"
    end

    test "remote advertises the same URL and protocol versions the server serves", %{conn: conn} do
      body = card(conn, "/api/mcp/server-card")
      resource = conn |> get("/.well-known/oauth-protected-resource") |> json_response(200)

      assert [remote] = body["remotes"]
      assert remote["type"] == "streamable-http"
      assert remote["url"] == resource["resource"]

      assert remote["supportedProtocolVersions"] ==
               EngramWeb.McpController.supported_protocol_versions()
    end

    test "keeps the SEP-1649 keys directories still read", %{conn: conn} do
      body = card(conn, "/api/mcp/server-card")

      assert body["serverInfo"] == EngramWeb.McpController.server_info()
      assert body["tools"] == Engram.MCP.Tools.wire_list()
    end

    test "on the dedicated MCP host, the card sits at <streamable-http-url>/server-card", %{
      conn: conn
    } do
      Application.put_env(:engram, :cors_origin, ["http://mcp.engram.page"])
      Application.put_env(:engram, :host_rewrite, mcp_host: "mcp.engram.page")

      conn = %{conn | host: "mcp.engram.page"} |> get("/server-card")

      assert conn.status == 200
      assert [%{"url" => "http://mcp.engram.page"}] = Jason.decode!(conn.resp_body)["remotes"]
    end
  end

  describe "HTTP semantics" do
    test "echoes the server-card media type when the client asks for it", %{conn: conn} do
      conn = conn |> put_req_header("accept", @card_type) |> get("/api/mcp/server-card")

      assert conn.status == 200
      assert [@card_type <> _] = get_resp_header(conn, "content-type")
    end

    test "falls back to application/json for a generic Accept", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get("/api/mcp/server-card")

      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    end

    test "serves an ETag and honours If-None-Match with 304", %{conn: conn} do
      first = get(conn, "/api/mcp/server-card")
      assert [etag] = get_resp_header(first, "etag")

      second =
        build_conn() |> put_req_header("if-none-match", etag) |> get("/api/mcp/server-card")

      assert second.status == 304
      assert second.resp_body == ""

      stale =
        build_conn() |> put_req_header("if-none-match", ~s("nope")) |> get("/api/mcp/server-card")

      assert stale.status == 200
    end

    for path <- @card_paths do
      test "#{path} carries the CORS headers the spec requires", %{conn: conn} do
        conn = get(conn, unquote(path))

        assert ["*"] = get_resp_header(conn, "access-control-allow-origin")
        assert [methods] = get_resp_header(conn, "access-control-allow-methods")
        assert methods =~ "GET"
        assert [allowed] = get_resp_header(conn, "access-control-allow-headers")
        assert allowed =~ "content-type"
        assert allowed =~ "if-none-match"
        assert ["etag"] = get_resp_header(conn, "access-control-expose-headers")
        assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
      end
    end
  end

  describe "GET /.well-known/ai-catalog.json" do
    test "points at the card with the spec's identifier and media types", %{conn: conn} do
      conn = get(conn, "/.well-known/ai-catalog.json")

      assert conn.status == 200
      assert ["application/ai-catalog+json" <> _] = get_resp_header(conn, "content-type")
      assert ["*"] = get_resp_header(conn, "access-control-allow-origin")

      resource =
        build_conn() |> get("/.well-known/oauth-protected-resource") |> json_response(200)

      assert %{"specVersion" => "1.0", "entries" => [entry]} = Jason.decode!(conn.resp_body)
      assert entry["identifier"] == "urn:air:engram.page:mcp:engram"
      assert entry["type"] == @card_type
      assert entry["url"] == resource["resource"] <> "/server-card"
    end

    test "is reachable on the dedicated MCP host and links its card there", %{conn: conn} do
      Application.put_env(:engram, :cors_origin, ["http://mcp.engram.page"])
      Application.put_env(:engram, :host_rewrite, mcp_host: "mcp.engram.page")

      conn = %{conn | host: "mcp.engram.page"} |> get("/.well-known/ai-catalog.json")

      assert conn.status == 200

      assert %{"entries" => [%{"url" => "http://mcp.engram.page/server-card"}]} =
               Jason.decode!(conn.resp_body)
    end
  end
end
