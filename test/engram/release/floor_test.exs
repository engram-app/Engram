defmodule Engram.Release.FloorTest do
  use ExUnit.Case, async: true

  alias Engram.Release.Floor

  # Release J, the release that stopped reading and writing
  # `folders.full_path_hmac` (Engram#2707).
  @release_j "release-v0.96.0"

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

  # 0.87.0 dropped the legacy Qdrant payload indexes, `p` included. 0.82.0
  # to 0.86.0 filter note deletes and counts on `p`, which prod's strict mode
  # (unindexed_filtering_update=false) refuses until a ~1.35M point rebuild.
  test "the floor covers the Qdrant legacy index drop" do
    assert Floor.at_least?("release-v0.87.0")
  end

  # S5 (Engram#2523): the write stop switches on with the floor at the
  # moved-folder feed release, and the tag must contain 2609
  # (`priv/release_floor_contains`).
  test "the floor covers the S5 moved-folder feed" do
    assert Floor.at_least?(Engram.Folders.WriteStop.reads_release())
  end

  # S6 step 1b (Engram#2523): root writes switch on with the floor at the
  # root-row readers' release (release D), and the tag must contain 2641
  # (`priv/release_floor_contains`).
  test "the floor covers the S6 root-row readers" do
    assert Floor.at_least?(Engram.Folders.Rows.root_reads_release())
  end

  # S6 step 4 (Engram#2523): release E stopped marker writes, and the tag must
  # contain 2649 (`priv/release_floor_contains`). Release J retires the folder
  # marker delete and the hash writes on the guarantee that no rollback target
  # inserts a marker again.
  test "the floor covers the S6 marker write stop" do
    assert Floor.at_least?("release-v0.91.0")
  end

  # S6 step 3, release K (Engram#2523): K drops `folders.full_path_hmac` and
  # `folders_full_path`. Release J stopped every read and write of both, so
  # the floor must be J: release I still reads the column.
  test "the floor covers release J's full_path_hmac retirement" do
    assert Floor.at_least?(@release_j)
  end
end
