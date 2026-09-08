defmodule EngramWeb.Plugs.RequirePluginVersionTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.PluginVersion
  alias EngramWeb.Plugs.RequirePluginVersion

  defp with_version(conn, value),
    do: Plug.Conn.put_req_header(conn, "x-plugin-version", value)

  describe "call/2" do
    test "passes when the header is absent", %{conn: conn} do
      result = RequirePluginVersion.call(conn, [])
      refute result.halted
      assert result.assigns[:plugin_version] == nil
    end

    test "passes and records the version when at the floor", %{conn: conn} do
      result =
        conn
        |> with_version(PluginVersion.minimum())
        |> RequirePluginVersion.call([])

      refute result.halted
      assert result.assigns[:plugin_version] == PluginVersion.minimum()
    end

    test "passes for an unparseable version", %{conn: conn} do
      refute conn |> with_version("nightly") |> RequirePluginVersion.call([]) |> Map.get(:halted)
    end

    test "426s below the floor with everything the client needs to recover", %{conn: conn} do
      result =
        conn
        |> with_version("1.0.0")
        |> RequirePluginVersion.call([])

      assert result.halted
      body = json_response(result, 426)
      assert body["error"] == "plugin_upgrade_required"
      assert body["min_version"] == PluginVersion.minimum()
      assert body["your_version"] == "1.0.0"
      assert body["update_url"] == PluginVersion.update_url()
    end

    test "records the version even on the refusal, so the block is countable", %{conn: conn} do
      result = conn |> with_version("1.0.0") |> RequirePluginVersion.call([])
      assert result.assigns[:plugin_version] == "1.0.0"
    end

    test "an over-long header is neither parsed nor echoed back", %{conn: conn} do
      # The body echoes `your_version`; an unbounded echo would let an
      # unauthenticated caller pick the size of our response.
      result =
        conn
        |> with_version(String.duplicate("9", 5000))
        |> RequirePluginVersion.call([])

      refute result.halted
    end
  end
end
