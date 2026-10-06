defmodule Engram.Notes.CrdtBridgeDiffPropertyTest do
  @moduledoc """
  Differential test for `CrdtBridge.text_diff/2` (#1877 item 3): the byte-level
  prefix/suffix diff must compute exactly the edit the old codepoint-list diff
  did, so the resulting `Yex.Text` ops are identical. The old implementation is
  kept here, and only here, as the oracle.
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

  # --- oracle: the pre-#1877 codepoint-list implementation -----------------

  defp oracle(current, incoming) do
    if current == incoming do
      :noop
    else
      cur = String.codepoints(current)
      inc = String.codepoints(incoming)
      prefix = cp_prefix(cur, inc, 0)
      cur_rest = Enum.drop(cur, prefix)
      inc_rest = Enum.drop(inc, prefix)

      suffix =
        cp_prefix(Enum.reverse(cur_rest), Enum.reverse(inc_rest), 0)
        |> min(length(cur_rest))
        |> min(length(inc_rest))

      deleted = Enum.take(cur_rest, length(cur_rest) - suffix)
      inserted = Enum.take(inc_rest, length(inc_rest) - suffix)
      {u16(Enum.take(cur, prefix)), u16(deleted), Enum.join(inserted)}
    end
  end

  defp cp_prefix([h | t1], [h | t2], acc), do: cp_prefix(t1, t2, acc + 1)
  defp cp_prefix(_, _, acc), do: acc

  defp u16(cps) do
    Enum.reduce(cps, 0, fn cp, acc ->
      <<code::utf8>> = cp
      acc + if code >= 0x10000, do: 2, else: 1
    end)
  end

  # ------------------------------------------------------------------------

  defp tokens, do: StreamData.map(list_of(member_of(@pool), max_length: 12), &Enum.join/1)

  defp text_with(content) do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)
    t = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    if content != "", do: Yex.Text.insert(t, 0, content)
    t
  end

  property "matches the codepoint oracle on edits sharing a prefix and suffix" do
    check all(a <- tokens(), b <- tokens(), c <- tokens(), d <- tokens(), max_runs: 2_000) do
      cur = a <> b <> c
      inc = a <> d <> c
      assert CrdtBridge.text_diff(cur, inc) == oracle(cur, inc)
    end
  end

  property "matches the codepoint oracle on unrelated strings" do
    check all(cur <- tokens(), inc <- tokens(), max_runs: 1_000) do
      assert CrdtBridge.text_diff(cur, inc) == oracle(cur, inc)
    end
  end

  property "diff_into_text converges the Y.Text to the incoming string" do
    check all(a <- tokens(), b <- tokens(), c <- tokens(), d <- tokens(), max_runs: 300) do
      t = text_with(a <> b <> c)
      :ok = CrdtBridge.diff_into_text(t, a <> d <> c)
      assert Yex.Text.to_string(t) == a <> d <> c
    end
  end

  test "edge cases agree with the oracle" do
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
      assert CrdtBridge.text_diff(cur, inc) == oracle(cur, inc), inspect({cur, inc})
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
    assert CrdtBridge.text_diff(base, inc) == oracle(base, inc)
  end
end
