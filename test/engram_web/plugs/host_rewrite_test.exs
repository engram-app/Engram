defmodule EngramWeb.Plugs.HostRewriteTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias EngramWeb.Plugs.HostRewrite

  describe "selfhost / unconfigured passthrough" do
    test "with no config, leaves conn untouched regardless of host" do
      conn =
        conn(:get, "/api/notes")
        |> Map.put(:host, "engram.ax")

      assert HostRewrite.call(conn, HostRewrite.init([])) == conn
    end

    test "with config but unmatched host, leaves conn untouched" do
      opts = HostRewrite.init(api_host: "api.engram.page", mcp_host: "mcp.engram.page")

      conn =
        conn(:get, "/api/notes")
        |> Map.put(:host, "engram.ax")

      assert HostRewrite.call(conn, opts) == conn
    end
  end
end
