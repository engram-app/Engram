defmodule Engram.SearchSnippetTest do
  use ExUnit.Case, async: true

  alias Engram.Search

  defp merged(fun), do: Enum.map_join(1..600, "\n\n", fun)

  test "an ordinary chunk's text is returned whole" do
    text = String.duplicate("a", 2_000)
    assert Search.snippet(text, "anything") == text
  end

  test "a merged chunk's text is a window around the best match" do
    text =
      merged(fn
        100 -> "Paragraph 100 mentions alpha alone."
        500 -> "Paragraph 500 has alpha and beta together."
        i -> "Paragraph #{i} of ordinary filler text."
      end)

    snippet = Search.snippet(text, "Alpha BETA")
    assert String.length(snippet) <= 1_500
    assert snippet =~ "alpha and beta together"
  end

  test "no match, or a non-text query: the first 1,500 chars" do
    text = merged(&"Paragraph #{&1} of ordinary filler text.")

    assert Search.snippet(text, "zebra") == String.slice(text, 0, 1_500)
    assert Search.snippet(text, {:similar, ["id"]}) == String.slice(text, 0, 1_500)
  end

  test "a match at the very end keeps a full-length window" do
    text = merged(&"Paragraph #{&1} of ordinary filler text.") <> "\n\nlast quixotic word"
    snippet = Search.snippet(text, "quixotic")

    assert String.length(snippet) == 1_500
    assert String.ends_with?(snippet, "last quixotic word")
  end

  test "multi-byte text slices on characters" do
    text = merged(&"Absatz #{&1} über Größe und Übermaß.") <> " zebraß"
    snippet = Search.snippet(text, "zebraß")

    assert String.valid?(snippet)
    assert snippet =~ "zebraß"
  end

  # Review M3: a note floored into one point per MiB could fill the top-k
  # with empty-snippet hits. Only its best floor point stays.
  test "a note's floor points collapse to its best one, in rank order" do
    hits = [
      %{vault_id: "v", source_path: "Log.md", text: "", score: 0.9},
      %{vault_id: "v", source_path: "A.md", text: "alpha", score: 0.8},
      %{vault_id: "v", source_path: "Log.md", text: "", score: 0.7},
      %{vault_id: "v", source_path: "Log.md", text: "", score: 0.6},
      %{vault_id: "v", source_path: "A.md", text: "beta", score: 0.5}
    ]

    assert Search.collapse_floor_hits(hits) == [
             %{vault_id: "v", source_path: "Log.md", text: "", score: 0.9},
             %{vault_id: "v", source_path: "A.md", text: "alpha", score: 0.8},
             %{vault_id: "v", source_path: "A.md", text: "beta", score: 0.5}
           ]
  end
end
