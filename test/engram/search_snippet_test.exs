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
end
