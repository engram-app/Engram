defmodule Engram.Native.MdOutlineTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.MCP.Sections
  alias Engram.Native

  # 2,508 notes (generated: ATX/setext headings at every depth, fences open
  # and closed, HTML blocks and comments, lists, callouts, tables, `%%` and
  # `$$` in and out of code, CRLF and lone CR, BOM, frontmatter, unicode,
  # plus eight large shapes) with Sections.outline/1's result as computed by
  # the mdex_native 0.2.9 scan before the port (#1877). One fix applied to
  # that oracle first: two `$$` pairs sharing a line made it blank
  # overlapping ranges and shift every later line (see sections_test, "math
  # pairs sharing a CRLF line"). A comrak bump must keep this green.
  @golden "test/support/fixtures/md_outline_golden.json.gz"

  defp shape({:ok, a}) do
    %{
      "headings" => Enum.map(a.headings, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end)),
      "explained" => a.explained |> MapSet.to_list() |> Enum.sort(),
      "safe" => Enum.map(a.safe_ranges, &Tuple.to_list/1)
    }
  end

  test "matches the pre-port scan on the golden corpus" do
    cases = @golden |> File.read!() |> :zlib.gunzip() |> Jason.decode!()
    assert length(cases) == 2_508
    wrong = for %{"in" => d, "out" => want} <- cases, shape(Sections.outline(d)) != want, do: d
    assert wrong == []
  end

  test "edge cases" do
    assert Native.md_outline("") == {[], [], []}
    assert {[{0, 1, "", "", 1}], [0], []} = Native.md_outline("#")

    # An unmatched delimiter stays text.
    assert {[{0, 2, "A **", "A **", 1}], [0], []} = Native.md_outline("## A **")

    # Astral text; a lone CR is a space (lines count "\n" only), not a break.
    assert {[{1, 1, "📝 x q", "📝 x q", 1}], [1], []} = Native.md_outline("a\r\n# 📝 x\rq")

    # BOM and frontmatter are blanked in the NIF; lines do not move.
    assert {[{3, 1, "B", "**B**", 1}], [3], []} =
             Native.md_outline("\uFEFF---\na: 1\n---\n# **B**\n")
  end

  test "a note with too many headings is refused, not returned" do
    assert Native.md_outline(String.duplicate("#\n", 100_001)) == nil
    assert {:error, :too_complex} = Sections.headings(String.duplicate("#\n", 100_001))
    assert {:ok, [_ | _]} = Sections.headings(String.duplicate("#\n", 1_000))
  end

  # Rust's str::trim and String.trim/1 must agree: both are Unicode
  # White_Space, so NBSP and friends trim and U+180E / U+200B do not.
  test "trims exactly what String.trim/1 trims" do
    for c <-
          [0x09, 0x0B, 0x0C, 0x85, 0xA0, 0x1680, 0x2000, 0x2007, 0x200A, 0x2028, 0x202F] ++
            [0x205F, 0x3000, 0x180E, 0x200B, 0xFEFF] do
      ws = <<c::utf8>>
      {[{_, _, text, raw, _}], _, _} = Native.md_outline("# a#{ws}\n")
      assert text == String.trim("a#{ws}"), "U+#{Integer.to_string(c, 16)}"
      assert raw == String.trim("a#{ws}"), "U+#{Integer.to_string(c, 16)}"
    end
  end

  describe "memory standard" do
    # comrak keeps every node (with its raw content) in an arena: ~100-250x
    # what it parses, worst on a tight list. The parse runs in ~64 KB
    # segments, so the arena is bounded by a segment, not the note (#1885);
    # what grows with the note is the result and a copy or two of the text.
    # Measured worst at the 10 MB note cap: 49 MB (10 MB of `%% \`a\``).
    test "native peak is a segment's arena plus a few times the input" do
      for d <- [
            String.duplicate("- a\n", 250_000),
            String.duplicate("*a* `b` [c](d) ", 70_000),
            String.duplicate("# h\n", 250_000),
            String.duplicate("> ", 500_000) <> "# x\n",
            String.duplicate("%% a %% $$ b $$\n", 60_000),
            String.duplicate("[r]: /u\n\n# [r] [s]\n\n", 50_000),
            # Refused (too many headings): parsing stops at the cap.
            String.duplicate("#\n", 5_000_000),
            # No safe cut anywhere: line table only, linear time.
            String.duplicate("\n", 10_000_000)
          ] do
        {_, peak} = Native.md_outline_nif(d)
        assert peak <= 5 * byte_size(d) + 50_000_000, "#{peak} for #{byte_size(d)} B"
      end
    end

    test "emits the NIF telemetry, always dirty" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Native.md_outline("# a\n")
      assert_receive {_, ^ref, %{input_bytes: 4}, %{nif: :md_outline, dirty: true}}
      :telemetry.detach(ref)
    end

    test "repeated calls leak nothing" do
      Engram.NativeLeak.assert_no_leak(fn ->
        Native.md_outline_nif("# a %% b %%\n\n$$\n# x\n$$\n\nS\n===\n")
      end)
    end
  end
end
