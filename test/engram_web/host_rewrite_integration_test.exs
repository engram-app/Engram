defmodule EngramWeb.HostRewriteIntegrationTest do
  use EngramWeb.ConnCase, async: false

  setup do
    prior = Application.get_env(:engram, :host_rewrite)
    Application.put_env(:engram, :host_rewrite, api_host: "api.engram.page", mcp_host: "mcp.engram.page")

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
end
