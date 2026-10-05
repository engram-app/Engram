# Regenerates chunker_golden.json.gz, which pins Markdown.parse/2's output
# (test/engram/native/chunker_test.exs). Run it only together with a
# @chunker_version bump (#1620): changed output without a bump means notes
# nobody edits keep chunks the new code would not produce.
#
#   MIX_ENV=test mix run --no-start test/support/fixtures/chunker_golden.gen.exs
:rand.seed(:exsss, {3, 14, 2026})

words =
  ~w(the note sync vault engram rust elixir search index chunk heading cost voyage embed qdrant
  frontmatter link tag folder title alpha beta gamma delta 日本語 テスト café naïve über 中文 العربية 🎉)

word = fn -> Enum.random(words) end
para = fn n -> Enum.map_join(1..n, " ", fn _ -> word.() end) end

blob = fn ->
  "![img](data:image/png;base64," <> Base.encode64(:crypto.strong_rand_bytes(120)) <> ")"
end

heading = fn lvl -> String.duplicate("#", lvl) <> " " <> para.(:rand.uniform(4)) end

block = fn ->
  case :rand.uniform(18) do
    1 ->
      heading.(1)

    n when n in 2..4 ->
      heading.(1 + :rand.uniform(5))

    5 ->
      "- " <> para.(5) <> "\n- " <> para.(4)

    6 ->
      Enum.map_join(1..(2 + :rand.uniform(8)), "\n\n", fn _ -> para.(20 + :rand.uniform(120)) end)

    7 ->
      blob.() <> " " <> para.(5)

    8 ->
      "#tag and [[Link]] and [md](x.md) " <> para.(8)

    9 ->
      "\n\n\n"

    10 ->
      "```sh\n# not a heading\n" <> para.(6) <> "\n```"

    11 ->
      para.(3) <> "\n" <> Enum.random(["===", "---"])

    12 ->
      "> # quoted\n> " <> para.(6)

    13 ->
      "| a | b |\n|---|---|\n| " <> para.(2) <> " | " <> para.(2) <> " |"

    14 ->
      "## Closing ##"

    15 ->
      "    indented code " <> para.(4)

    _ ->
      para.(10 + :rand.uniform(60))
  end
end

fm = fn ->
  Enum.random(["", "", "---\ntitle: FM Title\ntags: [a, b]\n---\n", "---\naliases: x\n---\n"])
end

gen = fn -> fm.() <> Enum.map_join(1..(1 + :rand.uniform(12)), "\n\n", fn _ -> block.() end) end
path = fn -> Enum.random(["Note.md", "dir/Sub Note.md", "a/b/c/Deep.md"]) end

hand = [
  {"", "x.md"},
  {"plain text", "x.md"},
  {"# Only Title\n\nBody text here.", "dir/T.md"},
  {"# Project Phoenix\n", "p.md"},
  {"---\ntitle: T\n---\n\nbody", "x.md"},
  {"Body\r\nwith CRLF\r\n\r\n## H2\r\nmore", "x.md"},
  {String.duplicate("word ", 2000), "big.md"},
  {String.duplicate("字", 3000), "cjk.md"},
  {"# Heading\n\n" <> String.duplicate("A", 10_000), "runt.md"}
]

cases = hand ++ for(_ <- 1..800, do: {gen.(), path.()})

slim = fn c ->
  cut = fn s -> binary_part(s, 0, byte_size(s) - byte_size(c.text)) end

  c
  |> Map.drop([:context_text, :embed_text])
  |> Map.merge(%{ctx: cut.(c.context_text), emb: cut.(c.embed_text)})
end

json =
  Enum.map(cases, fn {s, p} ->
    %{input: s, path: p, chunks: s |> Engram.Parsers.Markdown.parse(p) |> Enum.map(slim)}
  end)

File.write!(
  "test/support/fixtures/chunker_golden.json.gz",
  json |> Jason.encode!() |> :zlib.gzip()
)

IO.puts("#{length(json)} notes, #{json |> Enum.map(&length(&1.chunks)) |> Enum.sum()} chunks")
