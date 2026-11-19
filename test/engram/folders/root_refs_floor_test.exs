defmodule Engram.Folders.RootRefsFloorTest do
  # S6 step 1b (Engram#2523) writes root-row references, which only step 1a's
  # readers (#2641) take as the root. So the writers and the `root_refs`
  # ledger stay off until the rollback floor reaches 1a's release
  # (`Rows.root_writes?/1`); the test config assumes it.
  #
  # The floor-raise PR (a Todd yes, bundled with release E's floor raise)
  # sets `Rows.root_reads_release/0` to 1a's real tag, lists 2641's merge
  # commit in `priv/release_floor_contains`, and turns the first test into
  # `assert Rows.root_writes?(:enforce)`: from then on it fails unless
  # `priv/release_floor` is at or above that release.
  use ExUnit.Case, async: true

  alias Engram.Folders.Rows
  alias Engram.Release.Floor

  test "root writes wait for the rollback floor (sentinel until the raise)" do
    assert Rows.root_reads_release() == "release-v999.0.0"
    refute Floor.at_least?(Rows.root_reads_release())
    refute Rows.root_writes?(:enforce)
  end

  test ":assume (the test config) writes them" do
    assert Rows.root_writes?(:assume)
  end
end
