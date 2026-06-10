defmodule EngramWeb.HostRewriteIntegrationTest do
  use EngramWeb.ConnCase, async: false

  setup do
    prior = Application.get_env(:engram, :host_rewrite)

    Application.put_env(:engram, :host_rewrite,
      api_host: "api.engram.page",
      mcp_host: "mcp.engram.page"
    )

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:engram, :host_rewrite)
        _ -> Application.put_env(:engram, :host_rewrite, prior)
      end
    end)

    :ok
  end

  test "GET api.engram.page/notes hits the same controller as /api/notes", %{conn: conn} do
    conn = %{conn | host: "api.engram.page"} |> get("/notes")
    # 401/403 acceptable (unauth). 404 would mean the rewrite didn't land.
    assert conn.status in [401, 403]
  end

  test "GET mcp.engram.page/.well-known/oauth-protected-resource succeeds", %{conn: conn} do
    conn = %{conn | host: "mcp.engram.page"} |> get("/.well-known/oauth-protected-resource")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["resource"]
  end

  describe "saas-only mode" do
    setup do
      prior = Application.get_env(:engram, :host_rewrite)

      Application.put_env(:engram, :host_rewrite,
        api_host: "api.engram.page",
        mcp_host: "mcp.engram.page",
        reject_unknown_hosts: true,
        allowed_extra_hosts: []
      )

      on_exit(fn -> Application.put_env(:engram, :host_rewrite, prior) end)
      :ok
    end

    test "GET app.engram.page/anything returns 410 with api host pointer", %{conn: conn} do
      conn = %{conn | host: "app.engram.page"} |> get("/anything")
      assert conn.status == 410
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "gone"
      assert body["api_host"] == "api.engram.page"
    end

    test "GET api.engram.page/notes still rewrites under saas-only mode", %{conn: conn} do
      conn = %{conn | host: "api.engram.page"} |> get("/notes")
      assert conn.status in [401, 403]
    end
  end
end
