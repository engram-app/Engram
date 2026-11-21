defmodule Engram.Native.FrontmatterSplitTest do
  use ExUnit.Case, async: false

  alias Engram.Notes.Frontmatter

  # Captured from the Elixir Frontmatter.split/1 the day of the Rust port:
  # fence variants (CRLF, trailing blanks, `---x`, a BOM, EOF fences), 6,012
  # inputs, 2,640 with a block.
  @golden "test/support/fixtures/frontmatter_split_golden.json"
          |> File.read!()
          |> Jason.decode!(keys: :atoms)

  test "reproduces the Elixir split on the golden set" do
    for %{input: input, block: block, body: body} <- @golden do
      assert Frontmatter.split(input) == {block, body}, inspect(input)
    end
  end

  test "the body is a sub-binary of the input, not a copy" do
    content = "---\na: 1\n---\n" <> String.duplicate("x", 1_000_000)
    {_, body} = Frontmatter.split(content)
    assert :binary.referenced_byte_size(body) == byte_size(content)
  end

  test "invalid UTF-8 comes back byte for byte, as the regex split did" do
    content = "---\na: \xff\n---\nbody \xfe"
    assert Frontmatter.split(content) == {"a: \xff\n", "body \xfe"}
  end

  # The inline NIF reads at most 16 KB. A note without a leading fence, or
  # one whose fence closes early, is answered inline at any size; an
  # unclosed fence over many short lines (the scan's worst case) is handed
  # to the dirty variant, with the same answer.
  test "the inline split is budgeted and reschedules an unclosed fence" do
    ref = Engram.NativeScheduled.attach_nif_events()

    for content <- [
          String.duplicate("plain\n", 400_000),
          "---\na: 1\n---\n" <> String.duplicate("body\n", 400_000)
        ] do
      Frontmatter.split(content)
      n = byte_size(content)
      assert_receive {_, ^ref, %{input_bytes: ^n}, %{nif: :frontmatter_split, dirty: false}}
      refute_receive {_, ^ref, _, %{nif: :frontmatter_split}}, 50
    end

    unclosed = "---\n" <> String.duplicate("a: 1\n", 200_000)
    assert {:reschedule, _} = Engram.Native.frontmatter_split_nif(unclosed)
    {dirty, _} = Engram.Native.frontmatter_split_dirty_nif(unclosed)
    assert Engram.Native.frontmatter_split(unclosed) == dirty
    # One event for the call (the dirty rerun's, timed from the inline
    # attempt's start), not one per attempt.
    n = byte_size(unclosed)

    assert_receive {_, ^ref, %{input_bytes: ^n, duration: d},
                    %{nif: :frontmatter_split, dirty: true}}

    assert d > 0
    refute_receive {_, ^ref, _, %{nif: :frontmatter_split}}, 50

    closed_late = unclosed <> "---\nbody\n"
    {dirty, _} = Engram.Native.frontmatter_split_dirty_nif(closed_late)
    assert dirty != nil
    assert Engram.Native.frontmatter_split(closed_late) == dirty
  end

  test "split emits [:engram, :nif, :call, :stop]" do
    ref = Engram.NativeScheduled.attach_nif_events()
    Frontmatter.split("---\na: 1\n---\nb")
    assert_receive {_, ^ref, _, %{nif: :frontmatter_split}}
  end
end
