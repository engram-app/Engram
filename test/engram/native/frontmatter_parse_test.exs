defmodule Engram.Native.FrontmatterParseTest do
  # async: false: the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.Notes.Frontmatter

  # YamlElixir stays in the tree as the fallback, so it is the live oracle:
  # every block below must parse identically through the native-first
  # `parse/1` and the YamlElixir-only `parse_yaml/1` (same for ingest).

  @keys ~w(title type description tags aliases created date modified published
           rating source status author url id weight cssclasses) ++
          [
            "Key With Space",
            "ключ",
            "日本",
            "emoji😀",
            "a.b",
            "a-b",
            "_x",
            "x1",
            "123",
            "-1",
            "true",
            "null",
            "~",
            "-x",
            "?x",
            "key:colon",
            "key ",
            "a#b",
            "a,b",
            "a[b]",
            "'q'",
            "\"dq\"",
            ".x",
            "+x",
            "0x10",
            "1.5",
            "%x",
            "@x",
            "*x",
            "&x",
            "!x"
          ]

  @scalars [
    "plain words",
    "word",
    "",
    "~",
    "null",
    "Null",
    "NULL",
    "nULL",
    "true",
    "True",
    "TRUE",
    "tRUE",
    "false",
    "False",
    "FALSE",
    "yes",
    "no",
    "on",
    "off",
    "y",
    "n",
    "0",
    "007",
    "-0",
    "+5",
    "-12",
    "+",
    "-",
    "123456789012345678",
    "-123456789012345678",
    "1234567890123456789",
    "99999999999999999999999",
    "1.5",
    "1.",
    "-1.5",
    "1e5",
    "1E5",
    "1.5e-3",
    ".5",
    ".inf",
    "-.Inf",
    ".nan",
    ".NaN",
    "0x1F",
    "0x",
    "0o17",
    "0o",
    "0b101",
    "1_000",
    "1,000",
    "2024-01-15",
    "2024-01-15T10:00:00Z",
    "2024-01-15 10:00:00",
    "12:30",
    "12:30:45",
    "http://x.y/z?a=b&c=d#frag",
    "a: b",
    "a:b",
    "a :b",
    "a #c",
    "a#b",
    "a  #  c",
    "trailing:",
    "#tag",
    "[a, b]",
    "[a,b,c]",
    "[]",
    "[ ]",
    "[a,]",
    "[,a]",
    "[a,,b]",
    "[a, [b]]",
    "[a, {b: c}]",
    "['x', \"y z\"]",
    "[\"a, b\", 'c, d']",
    "[1, 2, -3, true, null, ~, 1.5]",
    "[a b, c d]",
    "[a: b]",
    "[a#b, c]",
    "[a #b]",
    "[a] #c",
    "[a]x",
    "[a",
    "{a: 1}",
    "{}",
    "'single'",
    "'it''s'",
    "''",
    "'a' # c",
    "'a'#c",
    "'a' x",
    "\"dq\"",
    "\"\"",
    "\"esc \\n \\t \\\" \\\\ \\/ \\u00e9\"",
    "\"\\u0001\"",
    "\"\\u0000\"",
    "\"\\x41\"",
    "\"\\U0001F600\"",
    "\"\\ud83d\"",
    "\"\\e\\a\\v\\0\\N\\_\\L\\P\"",
    "\"\\b\\f\\r\"",
    "\"\\ \"",
    "\"\\q\"",
    "\"a\" #c",
    "\"a\"#c",
    "\"a\" x",
    "\"unterminated",
    "'unterminated",
    "\"with 'single' inside\"",
    "'with \"double\" inside'",
    "&anchor v",
    "*alias",
    "!tag v",
    "!!str 5",
    "|",
    "|-",
    ">",
    "%x",
    "@x",
    "`x`",
    "-x",
    "- x",
    "--x",
    "-5x",
    "? x",
    "?x",
    ": x",
    ":x",
    ",x",
    "x,y",
    "x]",
    "x}",
    "ünïcødé",
    "日本語のテキスト",
    "😀 emoji",
    "a\u00A0b",
    "a\u0085b",
    "a\u2028b",
    "a\uFEFFb",
    "a\u007Fb",
    "a\u0001b",
    "tab\there",
    "multi  space",
    "ends with space ",
    "C:\\path\\to",
    "a \\ b",
    "50%",
    "a 'q' b",
    "a \"q\" b",
    "It's",
    "<b>html</b>",
    "{{template}}",
    "x: y: z"
  ]

  @line_noise [
    "",
    "   ",
    "# a comment",
    "  # indented comment",
    "#",
    "  continuation",
    "  nested: map",
    "    deep: x",
    "---",
    "...",
    "%YAML 1.1",
    "%TAG ! tag:x",
    "? complex",
    ": value",
    "- top level item",
    "\t",
    "key\twith: tab",
    "just text",
    "k: v\r"
  ]

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)

  defp entry do
    key = if :rand.uniform(5) == 1, do: pick(@keys), else: pick(Enum.take(@keys, 17))

    case :rand.uniform(12) do
      n when n <= 6 ->
        sep = pick([": ", ": ", ":  ", ":"])
        [key <> sep <> pick(@scalars) <> pick(["", "", "  ", " # c"])]

      n when n <= 9 ->
        indent = String.duplicate(" ", pick([0, 2, 2, 2, 4]))
        dash = pick(["- ", "- ", "-  ", "-"])

        items =
          for _ <- 1..:rand.uniform(4) do
            i = if :rand.uniform(8) == 1, do: pick([0, 1, 2, 3, 4, 6]), else: nil
            ind = if i, do: String.duplicate(" ", i), else: indent
            ind <> dash <> pick(@scalars)
          end

        [key <> pick([":", ":", ": ", ": # c"]) | items]

      10 ->
        [key <> ":"]

      _ ->
        [pick(@line_noise)]
    end
  end

  defp block do
    lines = Enum.flat_map(1..:rand.uniform(10), fn _ -> entry() end)
    Enum.join(lines, "\n") <> "\n"
  end

  # Entries the NIF accepts on their own, so the whole block exercises the
  # native rules' line interplay (lists ending, comments, blank lines)
  # instead of falling back on its first hostile line.
  defp friendly_entry(tries \\ 50) do
    e = entry()

    if tries == 0 or Engram.Native.frontmatter_parse(Enum.join(e, "\n") <> "\n") != nil,
      do: e,
      else: friendly_entry(tries - 1)
  end

  defp friendly_block do
    lines = Enum.flat_map(1..:rand.uniform(12), fn _ -> friendly_entry() end)
    Enum.join(lines, "\n") <> "\n"
  end

  # YamlElixir costs ~1.5 ms a block, so CI runs a few thousand cases.
  # After touching yaml.rs run more: ENGRAM_FM_CASES=100000 mix test <this>.
  @cases String.to_integer(System.get_env("ENGRAM_FM_CASES", "3000"))

  @realistic """
  title: "My note: a test"
  type: playbook
  description: Something long enough to be real text here
  created: 2024-01-15
  modified: 2024-02-01T10:00:00Z
  tags:
    - alpha
    - beta
  aliases: [one, two]
  published: true
  rating: 4
  source: https://example.com/a?b=c
  """

  test "a typical Obsidian block takes the native path" do
    assert [{"title", ~s("My note: a test")} | _] = Engram.Native.frontmatter_parse(@realistic)

    assert Frontmatter.parse(@realistic) ==
             {:ok,
              ~w(title type description created modified tags aliases published rating source),
              %{
                "title" => ~s("My note: a test"),
                "type" => ~s("playbook"),
                "description" => ~s("Something long enough to be real text here"),
                "created" => ~s("2024-01-15"),
                "modified" => ~s("2024-02-01T10:00:00Z"),
                "tags" => ~s(["alpha","beta"]),
                "aliases" => ~s(["one","two"]),
                "published" => "true",
                "rating" => "4",
                "source" => ~s("https://example.com/a?b=c")
              }, []}
  end

  test "comment-only and blank blocks parse to an empty map" do
    for b <- ["# c\n", "\n", "   \n# x\n\n"] do
      assert Engram.Native.frontmatter_parse(b) == []
      assert Frontmatter.parse(b) == Frontmatter.parse_yaml(b)
    end
  end

  # Where the NIF declines, parse/1 IS parse_yaml/1, so only the blocks it
  # answers need the (slow) oracle. Returns the mismatches.
  defp mismatches(blocks) do
    for b <- blocks,
        Engram.Native.frontmatter_parse(b) != nil,
        Frontmatter.parse(b) != Frontmatter.parse_yaml(b) or
          Frontmatter.parse_for_ingest(b) != Frontmatter.parse_for_ingest_yaml(b),
        do: b
  end

  @tag timeout: :infinity
  test "native parse matches YamlElixir on generated blocks" do
    :rand.seed(:exsss, {1877, 2, 3})
    blocks = for i <- 1..@cases, do: if(rem(i, 2) == 0, do: block(), else: friendly_block())
    assert mismatches(blocks) |> Enum.take(10) == []

    # The generator is mostly hostile; still, a real share must go native or
    # this test proves nothing about the native rules.
    native = Enum.count(blocks, &Engram.Native.frontmatter_parse/1)
    assert native > div(@cases, 10), "only #{native} blocks took the native path"
  end

  @tag timeout: :infinity
  test "every single generated line, alone, matches YamlElixir" do
    :rand.seed(:exsss, {1877, 4, 5})
    blocks = for _ <- 1..(@cases * 3), do: Enum.join(entry(), "\n") <> "\n"
    assert mismatches(blocks) |> Enum.take(10) == []
  end

  test "frontmatter of the note-meta golden corpus matches YamlElixir" do
    blocks =
      "test/support/fixtures/note_meta_golden.json"
      |> File.read!()
      |> Jason.decode!()
      |> Enum.flat_map(fn %{"input" => input} ->
        case Frontmatter.split(input) do
          {block, _} when is_binary(block) -> [block]
          _ -> []
        end
      end)

    assert length(blocks) > 1_000

    assert mismatches(blocks) |> Enum.take(10) == []
  end

  # Not in the generator: YamlElixir renames each `<<` key to a fresh
  # "<<N", so the oracle differs from itself run to run.
  test "the merge key << is left to YamlElixir" do
    assert Engram.Native.frontmatter_parse("<<: x\n") == nil
  end

  test "invalid UTF-8 goes to YamlElixir, never into the NIF" do
    b = "a: \xff\n"
    assert Frontmatter.parse(b) == Frontmatter.parse_yaml(b)
  end

  describe "memory standard" do
    test "native peak stays bounded on large blocks" do
      for b <- [
            String.duplicate("k: v\n", 1) <> "tags:\n" <> String.duplicate("  - item\n", 200_000),
            Enum.map_join(1..50_000, fn i -> "key#{i}: some value #{i}\n" end),
            "big: " <> String.duplicate("x", 2_000_000) <> "\n"
          ] do
        {_out, peak} = Engram.Native.frontmatter_parse_dirty_nif(b)
        assert peak <= 10 * byte_size(b), "#{peak} for #{byte_size(b)}"
      end
    end

    test "repeated calls leak nothing" do
      Engram.NativeLeak.assert_no_leak(fn ->
        Engram.Native.frontmatter_parse_nif(@realistic)
        Engram.Native.frontmatter_parse_nif("a: [1, \"x\"]\nb: {c: d}\n")
      end)
    end

    test "a block up to 16 KB parses on the calling scheduler, a bigger one dirty" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Frontmatter.parse("a: " <> String.duplicate("x", 16_000) <> "\n")
      assert_receive {_, ^ref, _, %{nif: :frontmatter_parse, dirty: false}}
      Frontmatter.parse("a: " <> String.duplicate("x", 17_000) <> "\n")
      assert_receive {_, ^ref, _, %{nif: :frontmatter_parse, dirty: true}}
    end
  end
end
