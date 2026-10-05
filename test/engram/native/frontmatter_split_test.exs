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

  test "split emits [:engram, :nif, :call, :stop]" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
    Frontmatter.split("---\na: 1\n---\nb")
    assert_receive {_, ^ref, _, %{nif: :frontmatter_split}}
  end
end
