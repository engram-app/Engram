defmodule Engram.Notes.CrdtBridgeDiffPropertyTest do
  @moduledoc """
  `CrdtBridge.diff_into_text/2` end to end: the `Yex.Text` converges to the
  incoming string, and invalid UTF-8 raises before any mutation. The span
  itself is pinned against the old Elixir diff in
  `test/engram/native/text_diff_test.exs`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Engram.Notes.CrdtBridge

  # Tokens chosen so byte-level LCP/LCS lands mid-character: shared lead bytes
  # (é/ê, 😀/😁/🙂), shared trailing continuation bytes (é/©), combining marks,
  # CJK, ZWJ sequences, plus plain ASCII.
  @pool [
    "a",
    "b",
    " ",
    "\n",
    "é",
    "ê",
    "©",
    "é",
    "́",
    "中",
    "丫",
    "😀",
    "😁",
    "🙂",
    "👍🏽",
    "👩‍💻",
    "\u{10FFFF}",
    "\u{FFFF}"
  ]

  defp tokens, do: StreamData.map(list_of(member_of(@pool), max_length: 12), &Enum.join/1)

  defp text_with(content) do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)
    t = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    if content != "", do: Yex.Text.insert(t, 0, content)
    t
  end

  property "diff_into_text converges the Y.Text to the incoming string" do
    check all(a <- tokens(), b <- tokens(), c <- tokens(), d <- tokens(), max_runs: 300) do
      t = text_with(a <> b <> c)
      :ok = CrdtBridge.diff_into_text(t, a <> d <> c)
      assert Yex.Text.to_string(t) == a <> d <> c
    end
  end

  test "edge cases converge" do
    cases = [
      {"", ""},
      {"", "😀"},
      {"😀", ""},
      {"same", "same"},
      {"abc", "xyz"},
      {"é", "ê"},
      {"é", "©"},
      {"😀😀", "😀😁😀"},
      {"aaa", "aa"},
      {"aa", "aaa"},
      {"é", "e"},
      {"中文", "中丫文"}
    ]

    for {cur, inc} <- cases do
      t = text_with(cur)
      :ok = CrdtBridge.diff_into_text(t, inc)
      assert Yex.Text.to_string(t) == inc, inspect({cur, inc})
    end
  end

  test "invalid UTF-8 incoming raises before mutating the text" do
    t = text_with("abc")

    assert_raise ArgumentError, fn -> CrdtBridge.diff_into_text(t, <<0xFF, "x">>) end
    assert_raise ArgumentError, fn -> CrdtBridge.diff_into_text(t, <<"abc", 0xC3>>) end
    assert Yex.Text.to_string(t) == "abc"
  end

  test "ingest_plaintext rejects invalid UTF-8 before touching frontmatter or body" do
    doc = CrdtBridge.new_doc()
    :ok = CrdtBridge.ingest_plaintext(doc, "---\ntitle: old\n---\nbody\n")
    before = CrdtBridge.text_of(doc)

    assert_raise ArgumentError, fn ->
      CrdtBridge.ingest_plaintext(doc, "---\ntitle: new\n---\nbody " <> <<0xFF>>)
    end

    assert CrdtBridge.text_of(doc) == before
  end

  test "large note: 4 MB body with a mid-document edit" do
    base = String.duplicate("line of text with ü and 😀\n", 150_000)
    {head, tail} = String.split_at(base, div(String.length(base), 2))
    inc = head <> "INSERTED 中" <> tail
    t = text_with(base)
    :ok = CrdtBridge.diff_into_text(t, inc)
    assert Yex.Text.to_string(t) == inc
  end
end
