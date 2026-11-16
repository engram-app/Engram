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

  alias Engram.Folders.WriteStop
  alias Engram.PluginVersion
  alias Engram.Release.Floor

  # One source of truth: the constants the gate itself reads.
  test "a rollback cannot land below the S5 readers release" do
    assert Floor.at_least?(WriteStop.reads_release())
  end

  test "plugins without folder ops are refused, the S4 plugin is not" do
    refute PluginVersion.supported?("1.39.3")
    assert PluginVersion.supported?(WriteStop.s4_plugin())
  end

  test "the write stop's floor check passes as prod runs it" do
    assert WriteStop.floors?(:enforce)
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
