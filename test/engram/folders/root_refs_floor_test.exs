defmodule Engram.Folders.RootRefsFloorTest do
  # S6 step 1b (Engram#2523) writes root-row references, which only step 1a's
  # readers (#2641) take as the root. So the writers and the `root_refs`
  # ledger wait for the rollback floor to reach 1a's release, release D
  # (`Rows.root_writes?/1`); the test config assumes it. The floor-raise PR
  # set `Rows.root_reads_release/0` to D's tag and listed 2641's merge commit
  # in `priv/release_floor_contains`; the first test pins it.
  use ExUnit.Case, async: true

  alias Engram.Folders.Rows
  alias Engram.Release.Floor

  test "the rollback floor reaches the root-row readers' release" do
    assert Floor.at_least?(Rows.root_reads_release())
    assert Rows.root_writes?(:enforce)
  end

  test ":assume (the test config) writes them" do
    assert Rows.root_writes?(:assume)
  end
end
