defmodule Engram.Search.CollapseToNotesTest do
  use ExUnit.Case, async: true
  alias Engram.Search

  defp chunk(path, vid, score, vec, extra \\ %{}) do
    Map.merge(
      %{
        source_path: path,
        vault_id: vid,
        score: score,
        vector: vec,
        title: "T",
        heading_path: "H",
        text: "best?"
      },
      extra
    )
  end

  test "one rep per {vault_id, source_path}, best chunk wins, match_count counts the group" do
    chunks = [
      chunk("a.md", "v1", 0.7, [1.0, 0.0], %{text: "low"}),
      chunk("a.md", "v1", 0.9, [1.0, 0.0], %{text: "high", title: "Best A"}),
      chunk("b.md", "v1", 0.5, [0.0, 1.0], %{text: "only B"})
    ]

    reps = Search.collapse_to_notes(chunks)
    by_path = Map.new(reps, &{&1.source_path, &1})

    assert map_size(by_path) == 2
    assert by_path["a.md"].score == 0.9
    assert by_path["a.md"].text == "high"
    assert by_path["a.md"].title == "Best A"
    assert by_path["a.md"].vector == [1.0, 0.0]
    assert by_path["a.md"].match_count == 2
    assert by_path["b.md"].match_count == 1
  end

  test "same source_path in different vaults stays distinct" do
    chunks = [
      chunk("note.md", "v1", 0.8, [1.0, 0.0]),
      chunk("note.md", "v2", 0.6, [0.0, 1.0])
    ]

    reps = Search.collapse_to_notes(chunks)
    assert length(reps) == 2
    assert Enum.sort(Enum.map(reps, & &1.vault_id)) == ["v1", "v2"]
  end

  test "drops chunks with nil source_path" do
    chunks = [chunk("a.md", "v1", 0.9, [1.0, 0.0]), chunk(nil, "v1", 0.95, [1.0, 0.0])]
    reps = Search.collapse_to_notes(chunks)
    assert Enum.map(reps, & &1.source_path) == ["a.md"]
  end
end
