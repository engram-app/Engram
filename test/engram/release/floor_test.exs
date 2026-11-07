defmodule Engram.Release.FloorTest do
  use ExUnit.Case, async: true

  alias Engram.Release.Floor

  test "the floor is priv/release_floor, a release-vX.Y.Z tag" do
    assert Floor.tag() == "priv/release_floor" |> File.read!() |> String.trim()
    assert Floor.tag() =~ ~r/\Arelease-v\d+\.\d+\.\d+\z/
  end

  # The floor as of 2026-11-07. A raise is a PR changing priv/release_floor
  # and this line (docs/context/rollback-floor.md).
  test "the floor is release-v0.76.0" do
    assert Floor.tag() == "release-v0.76.0"
  end

  test "at_least?/1 compares versions, not strings" do
    assert Floor.at_least?("release-v0.76.0")
    assert Floor.at_least?("release-v0.9.0")
    refute Floor.at_least?("release-v0.76.1")
    refute Floor.at_least?("release-v0.100.0")
  end
end
