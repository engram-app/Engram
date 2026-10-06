defmodule Engram.Native.TextDiffTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Engram.Native

  # The Elixir diff this NIF replaced (CrdtBridge.diff_into_text/2 before
  # #1873), kept as the oracle: {prefix_u16, delete_u16, inserted}.
  defp reference(current, incoming) do
    cur = String.codepoints(current)
    inc = String.codepoints(incoming)
    prefix = common_prefix_len(cur, inc, 0)
    cur_rest = Enum.drop(cur, prefix)
    inc_rest = Enum.drop(inc, prefix)

    suffix =
      common_prefix_len(Enum.reverse(cur_rest), Enum.reverse(inc_rest), 0)
      |> min(length(cur_rest))
      |> min(length(inc_rest))

    {utf16_units(Enum.take(cur, prefix)),
     utf16_units(Enum.take(cur_rest, length(cur_rest) - suffix)),
     Enum.join(Enum.take(inc_rest, length(inc_rest) - suffix))}
  end

  defp common_prefix_len([h | t1], [h | t2], acc), do: common_prefix_len(t1, t2, acc + 1)
  defp common_prefix_len(_, _, acc), do: acc

  defp utf16_units(cps),
    do: Enum.reduce(cps, 0, fn <<c::utf8>>, acc -> acc + if(c >= 0x10000, do: 2, else: 1) end)

  defp nif(current, incoming) do
    {p, d, start, len} = Native.text_diff(current, incoming)
    {p, d, binary_part(incoming, start, len)}
  end

  # Few distinct units so prefixes and suffixes overlap often: ASCII, a
  # 2-byte, a 3-byte, two astral (surrogate-pair) codepoints, a combining mark.
  @units ["a", "b", " ", "\n", "é", "€", "📝", "🚀", <<0x301::utf8>>]

  defp text, do: StreamData.list_of(StreamData.member_of(@units)) |> StreamData.map(&Enum.join/1)

  property "matches the Elixir diff on generated text" do
    check all(current <- text(), incoming <- text(), max_runs: 2_000) do
      assert nif(current, incoming) == reference(current, incoming)
    end
  end

  property "matches on an edit inside shared text" do
    check all(
            base <- text(),
            at <- StreamData.integer(0..100),
            ins <- text(),
            del <- StreamData.integer(0..5),
            max_runs: 2_000
          ) do
      cps = String.codepoints(base)
      at = min(at, length(cps))
      incoming = Enum.join(Enum.take(cps, at)) <> ins <> Enum.join(Enum.drop(cps, at + del))
      assert nif(base, incoming) == reference(base, incoming)
    end
  end

  test "edge cases" do
    assert nif("", "") == {0, 0, ""}
    assert nif("", "abc") == {0, 0, "abc"}
    assert nif("abc", "") == {0, 3, ""}
    assert nif("same", "same") == {4, 0, ""}
    # Repeated text: the suffix may not overlap the prefix.
    assert nif("aaa", "aaaa") == {3, 0, "a"}
    assert nif("aaaa", "aa") == {2, 2, ""}
    # A shared lead byte of different codepoints is not a shared codepoint.
    assert nif("é", "ê") == {0, 1, "ê"}
    assert nif("x📝y", "x🚀y") == {1, 2, "🚀"}
  end

  test "large inputs go to the dirty scheduler and agree with the inline one" do
    big = String.duplicate("prose 📝 ", 10_000)
    incoming = big <> "tail"

    assert Native.text_diff(big, incoming) == elem(Native.text_diff_nif(big, incoming), 0)
    assert Native.text_diff(big, incoming) == elem(Native.text_diff_dirty_nif(big, incoming), 0)
  end

  describe "memory standard" do
    test "native peak is constant, not proportional to the note" do
      big = String.duplicate("prose 📝 ", 200_000)
      {_, peak} = Native.text_diff_dirty_nif(big, "x" <> big <> "y")
      assert peak <= 1_024
    end

    test "repeated calls leak nothing" do
      Engram.NativeLeak.assert_no_leak(fn ->
        Native.text_diff_nif("hello 📝 world", "hello brave world")
      end)
    end
  end

  test "16 KB runs on the calling scheduler, a byte more dirty" do
    Engram.NativeScheduled.assert_scheduled(
      :text_diff,
      &Native.text_diff(String.duplicate("a", &1 - 1), "b")
    )
  end
end
