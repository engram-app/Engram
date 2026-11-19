defmodule Engram.Folders.WriteStopFloorTest do
  # S5 (Engram#2523) is a write stop: from it, a note under a renamed folder
  # keeps its old stored path. Release A ships the moved-folder feed and the
  # shown-path announces with the writer inert; release B raises the rollback
  # floor to A, which switches it on (`docs/context/rollback-floor.md`). The
  # first test pins it.
  #
  # No plugin floor: plugins older than S4 learn such a move from the
  # moved-folder feed (`Engram.Sync.moved_feed?/1`), so they keep syncing.
  use ExUnit.Case, async: true

  alias Engram.Folders.WriteStop
  alias Engram.PluginVersion
  alias Engram.Release.Floor
  alias Engram.Sync

  test "the rollback floor reaches the moved-folder feed release" do
    assert Floor.at_least?(WriteStop.reads_release())
    assert WriteStop.floors?(:enforce)
  end

  test "plugins older than S4 still sync, and get the moved-folder feed" do
    assert PluginVersion.supported?("1.39.3")
    assert Sync.moved_feed?("1.39.3")
    assert Sync.moved_feed?("1.39.4-pr.689.g23b5eee")
  end

  # 1.40.0 shipped without working moved-folder handling (e2e test_108: no
  # notes or attachments under an uncascaded-moved folder), so no released
  # plugin may skip the feed until one is proven to handle it.
  test "released plugins at and past 1.40.0 still get the moved-folder feed" do
    assert Sync.moved_feed?("1.40.0")
    assert Sync.moved_feed?("1.41.0")
    assert Sync.moved_feed?("2.0.0")
    refute Sync.moved_feed?(WriteStop.s4_plugin())
  end

  test "a client with no readable version gets the moved-folder feed" do
    assert Sync.moved_feed?(nil)
    assert Sync.moved_feed?("not-a-version")
  end
end
