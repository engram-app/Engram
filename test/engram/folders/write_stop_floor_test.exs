defmodule Engram.Folders.WriteStopFloorTest do
  # S5 (Engram#2523) is a write stop: from it, a note under a renamed folder
  # keeps its old stored path, and only a reader that derives paths from the
  # folder chain (Gap A, PR 2606) plus a plugin that learns folder moves from
  # `folder_changed` (S4, plugin PR 689) sees the new one. So this release may
  # ship only once both floors cover them. RED BY DESIGN until the S4.5
  # release raises them (`docs/context/rollback-floor.md`,
  # `docs/context/plugin-version-floor.md`): an owner decision, after the S4
  # plugin's adoption check. If the S4 plugin ships under another version,
  # change `@s4_plugin` to it.
  use EngramWeb.ConnCase, async: true

  alias Engram.PluginVersion
  alias Engram.Release.Floor

  # release-please's next minor after 1.39.3 for plugin PR 689's `feat:`.
  @s4_plugin "1.40.0"
  # The first release that reads folders by their chain (Gap A) and carries
  # the S4.5 plugin floor. Set to the real S4.5 tag when it is cut.
  @s4_5_release "release-v0.86.0"

  test "a rollback cannot land below S4.5" do
    assert Floor.at_least?(@s4_5_release)
  end

  test "plugins without folder ops are refused, the S4 plugin is not" do
    refute PluginVersion.supported?("1.39.3")
    assert PluginVersion.supported?(@s4_plugin)
  end

  describe "the HTTP seam" do
    setup :authed_api_conn

    test "an old plugin gets 426", %{conn: conn} do
      conn
      |> put_req_header("x-plugin-version", "1.39.3")
      |> get(~p"/api/sync/manifest")
      |> json_response(426)
    end
  end
end
