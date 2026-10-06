defmodule Engram.Native.Utf16OffsetsTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Engram.Native

  # The per-edit conversion the rewriter used before (#1877), as the oracle.
  defp reference(text, offsets) do
    for at <- offsets do
      text
      |> binary_part(0, at)
      |> :unicode.characters_to_binary(:utf8, {:utf16, :big})
      |> byte_size()
      |> div(2)
    end
  end

  @units ["a", " ", "\n", "é", "€", "📝", "🚀", <<0x301::utf8>>, "[[x]]"]

  defp text, do: StreamData.list_of(StreamData.member_of(@units)) |> StreamData.map(&Enum.join/1)

  # Codepoint-boundary byte offsets of `text`, 0 and the end included.
  defp boundaries(text) do
    [0 | text |> String.codepoints() |> Enum.scan(0, &(byte_size(&1) + &2))]
  end

  property "matches the per-offset conversion on generated text" do
    check all(
            t <- text(),
            picks <- StreamData.list_of(StreamData.integer(0..1_000)),
            max_runs: 2_000
          ) do
      bs = boundaries(t)
      offsets = picks |> Enum.map(&Enum.at(bs, rem(&1, length(bs)))) |> Enum.sort()
      assert Native.utf16_offsets(t, offsets) == reference(t, offsets)
    end
  end

  test "edge cases" do
    assert Native.utf16_offsets("", []) == []
    assert Native.utf16_offsets("", [0]) == [0]
    assert Native.utf16_offsets("a📝é€b", [0, 1, 5, 7, 10, 11]) == [0, 1, 3, 4, 5, 6]

    # Inside a codepoint, past the end, unsorted, negative: refused.
    for bad <- [[2], [12], [5, 1], [-1]] do
      assert_raise ArgumentError, fn -> Native.utf16_offsets("a📝é€b", bad) end
    end
  end

  test "large inputs go to the dirty scheduler and agree with the inline one" do
    big = String.duplicate("prose 📝 ", 10_000)
    at = [0, 6, byte_size(big)]
    assert Native.utf16_offsets(big, at) == elem(Native.utf16_offsets_nif(big, at), 0)
    assert Native.utf16_offsets(big, at) == elem(Native.utf16_offsets_dirty_nif(big, at), 0)
  end

  describe "memory standard" do
    test "native peak is the output list, not the text" do
      big = String.duplicate("prose 📝 ", 200_000)
      # Every 11 bytes is the start of a "prose 📝 " unit, a boundary.
      at = Enum.to_list(0..109_989//11)
      {_, peak} = Native.utf16_offsets_dirty_nif(big, at)
      assert peak <= 8 * length(at) + 1_024
    end

    test "repeated calls leak nothing" do
      Engram.NativeLeak.assert_no_leak(fn -> Native.utf16_offsets_nif("a📝 [[b]]", [0, 5, 7]) end)
    end
  end

  test "16 KB runs on the calling scheduler, a byte more dirty" do
    Engram.NativeScheduled.assert_scheduled(
      :utf16_offsets,
      &Native.utf16_offsets(String.duplicate("a", &1), [0])
    )
  end
end
