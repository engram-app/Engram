defmodule Engram.Native.ChunkerTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.Parsers.Markdown

  # Captured from the Elixir chunker the day of the Rust port: 2,008 notes,
  # 5,690 chunks, avoiding code syntax and setext underlines. context_text is
  # stored as its prefix to halve the fixture.
  @golden "test/support/fixtures/chunker_golden.json.gz"
          |> File.read!()
          |> :zlib.gunzip()
          |> Jason.decode!(keys: :atoms)

  test "reproduces the Elixir chunker on the golden set" do
    for %{input: input, path: path, chunks: expected} <- @golden do
      expected =
        Enum.map(expected, fn c ->
          c |> Map.delete(:prefix) |> Map.put(:context_text, c.prefix <> c.text)
        end)

      assert Markdown.parse(input, path) == expected, inspect({input, path})
    end
  end

  test "invalid UTF-8 is scrubbed, not crashed on" do
    assert [%{text: "a � b"}] = Markdown.parse("a \xFF b", "x.md")
  end

  describe "memory standard" do
    test "native peak stays bounded on large notes" do
      for content <- [
            String.duplicate("## H\n\n" <> String.duplicate("word ", 500) <> "\n\n", 400),
            "![i](data:image/png;base64," <>
              Base.encode64(:crypto.strong_rand_bytes(1_500_000)) <> ")"
          ] do
        {_chunks, peak} = Engram.Native.chunk_dirty_nif(content, nil, "f", "T")
        assert peak <= 10 * byte_size(content), "#{peak} for #{binary_part(content, 0, 20)}"
      end
    end

    test "repeated calls leak nothing" do
      args = ["# A\n\ntext `c`\n\n## B\n\nmore", "tags: [a]", "f", "T"]
      apply(Engram.Native, :chunk_nif, args)
      before = Engram.Native.live_bytes()
      for _ <- 1..300, do: apply(Engram.Native, :chunk_nif, args)
      assert Engram.Native.live_bytes() - before == 0
    end

    test "parse emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Markdown.parse("# a\n\nb", "x.md")
      assert_receive {[:engram, :nif, :call, :stop], ^ref, _, %{nif: :chunk, dirty: false}}
    end
  end
end
