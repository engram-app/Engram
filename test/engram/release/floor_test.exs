defmodule Engram.Release.FloorTest do
  use ExUnit.Case, async: true

  alias Engram.Release.Floor

  test "the floor is priv/release_floor, a release-vX.Y.Z tag" do
    assert Floor.tag() == "priv/release_floor" |> File.read!() |> String.trim()
    assert Floor.tag() =~ ~r/\Arelease-v\d+\.\d+\.\d+\z/
    assert Floor.version() == Version.parse!(String.replace_prefix(Floor.tag(), "release-v", ""))
  end

  # Relative to the file, so raising the floor edits one place.
  test "at_least?/1 compares versions, not strings" do
    %Version{major: ma, minor: mi, patch: pa} = Floor.version()
    tag = fn ma, mi, pa -> "release-v#{ma}.#{mi}.#{pa}" end

    assert Floor.at_least?(Floor.tag())
    assert Floor.at_least?(tag.(ma, 0, 0))
    refute Floor.at_least?(tag.(ma, mi, pa + 1))
    # One more digit and a leading 1 (0.176 for 0.76): above as a version,
    # below as a string.
    refute Floor.at_least?(tag.(ma, mi + 10 ** length(Integer.digits(mi)), 0))
  end

  # R8: bodies are read from note_bodies from 0.76 on (Engram.Notes.NoteBody).
  test "the floor covers R8's requirement" do
    assert Floor.at_least?("release-v0.76.0")
  end
end
