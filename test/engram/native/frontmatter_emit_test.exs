defmodule Engram.Native.FrontmatterEmitTest do
  # async: false: the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.Notes.Frontmatter

  # Ymlr stays in the tree as the fallback, so it is the live oracle: where
  # the NIF renders a key, the bytes must equal Frontmatter.emit_key/2 (Ymlr).
  # content_hash is taken over this text, so ANY drift re-embeds every note.

  @cases String.to_integer(System.get_env("ENGRAM_FM_CASES", "3000"))

  @exact ~w(~ ? - null Null NULL y Y n N yes Yes YES no No NO true True TRUE false
            False FALSE on On ON off Off OFF nULL tRUE yES) ++ [""]

  @prefixes [" ", "\t", "!", "&", "*", "{", "}", "[", "]", ",", "#", "|", ">", "@", "`"] ++
              ["\"", "- ", ": ", ":{", "%", "? ", "0b", "0o", "0x", ".inf", ".Inf", ".INF"] ++
              ["+.inf", "+.Inf", "-.inf", "-.INF", ".nan", ".Nan", ".NAN", "'", "-", ":", "?"]

  @alphabet String.graphemes("ab Zxy09.-+eE:#'\"\\,[]{}!&*|>@`%~?_/") ++
              ["\n", "\t", "\r", "\u00A0", "\u0085", "\u2028", "\u2029", "\u0001", "\u0007"] ++
              ["\u001B", "\u007F", "\u0080", "\u009F", "\u00FF", "é", "日", "😀", "\uFEFF"] ++
              ["\uFFFE", "\u000B", "\u000C", "\u0000", "\u0100", "\u{10FFFF}", " #", ": "]

  @numeric ~w(0 1 -1 +1 007 1.5 -1.5 1. .5 1e5 1E5 1e+5 1e-5 1.5e10 1e 1e+ 1.5.5 1e5e5
              123456789012345678901234567890 1_000 0x1F 1,000 -0 +0 1e99 1e100 1e999)

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)

  defp rand_string(max) do
    for(_ <- 0..:rand.uniform(max), do: pick(@alphabet)) |> Enum.join()
  end

  defp string do
    case :rand.uniform(10) do
      1 ->
        pick(@exact)

      2 ->
        pick(@prefixes) <> rand_string(4)

      3 ->
        pick(@numeric)

      4 ->
        pick(@numeric) <> pick(["", " ", ":", "x", "\n"])

      5 ->
        Enum.map_join(1..:rand.uniform(4), "\n", fn _ -> rand_string(3) end) <>
          pick(["", "\n", "\n\n", "\n\n\n"])

      6 ->
        "\n"

      _ ->
        rand_string(8)
    end
  end

  defp value(depth \\ 0) do
    case :rand.uniform(if depth > 2, do: 6, else: 9) do
      n when n <= 3 -> string()
      4 -> pick([true, false, nil])
      5 -> pick([0, 1, -5, 42, 1_234_567_890_123, 98_765_432_109_876_543_210_123])
      6 -> pick([1.5, -0.0, 1.0e20, 0.1])
      7 -> for _ <- 1..:rand.uniform(4), do: value(depth + 1)
      8 -> pick([[], %{}, [nil, ""], [[]], [%{}]])
      _ -> Map.new(1..pick([1, 2, 3, 5, 33, 40]), fn _ -> {string(), value(depth + 1)} end)
    end
  end

  defp pair do
    key = if :rand.uniform(3) == 1, do: string(), else: pick(~w(title tags aliases a b))

    json =
      case :rand.uniform(20) do
        1 -> pick(["not json", "{bad", "1.0", "-0", "1e400", " \"x\" ", "\"\\ud800\"", ""])
        _ -> Jason.encode!(value())
      end

    {key, json}
  end

  defp mismatches(pairs) do
    pairs
    |> Enum.zip(Engram.Native.frontmatter_emit(pairs))
    |> Enum.flat_map(fn
      {_, nil} ->
        []

      {{k, v}, yaml} ->
        expected = Frontmatter.emit_key(k, v)
        if yaml == expected, do: [], else: [{k, v, yaml, expected}]
    end)
  end

  test "renders like Ymlr on generated keys and values" do
    :rand.seed(:exsss, {1877, 6, 7})
    pairs = for _ <- 1..(@cases * 5), do: pair()
    assert mismatches(pairs) |> Enum.take(10) == []

    native = pairs |> Engram.Native.frontmatter_emit() |> Enum.count(& &1)
    assert native > @cases, "only #{native} keys rendered natively"
  end

  test "renders the realistic shapes natively, byte for byte" do
    values = %{
      "title" => ~s("My note: a test"),
      "tags" => ~s(["alpha","beta"]),
      "created" => ~s("2024-01-15"),
      "published" => "true",
      "rating" => "4",
      "empty" => "null",
      "nested" => ~s({"b":[1,{"c":"d"}],"a":"x"}),
      "multi" => ~s("line one\\nline two\\n")
    }

    pairs = Enum.to_list(values)
    assert Enum.all?(Engram.Native.frontmatter_emit(pairs))
    assert mismatches(pairs) == []
  end

  test "emit/3 equals the all-Ymlr render, raws and fallbacks included" do
    order = ~w(title rating raw tags float missing title)

    values = %{
      "title" => ~s("T"),
      "rating" => "4",
      "tags" => ~s(["a"]),
      "float" => "1.5",
      "raw" => "unused"
    }

    raws = %{"raw" => "raw: [a, b"}

    expected =
      ~w(title rating raw tags float title)
      |> Enum.map_join(fn
        "raw" -> "raw: [a, b\n"
        k -> Frontmatter.emit_key(k, values[k])
      end)

    assert Frontmatter.emit(order, values, raws) == expected
  end

  test "non-binary and invalid UTF-8 values go to Ymlr, not the NIF" do
    assert Frontmatter.emit(["a", "b"], %{"a" => 5, "b" => "\"\xff\""}) ==
             Frontmatter.emit_key("a", 5) <> Frontmatter.emit_key("b", "\"\xff\"")
  end

  describe "memory standard" do
    test "native peak stays bounded on large values" do
      for pairs <- [
            [{"big", Jason.encode!(String.duplicate("line of text\n", 100_000))}],
            [{"list", Jason.encode!(Enum.map(1..100_000, &"item #{&1}"))}],
            Enum.map(1..20_000, &{"key#{&1}", Jason.encode!("value #{&1}")})
          ] do
        bytes = Enum.reduce(pairs, 0, fn {k, v}, acc -> acc + byte_size(k) + byte_size(v) end)
        {_out, peak} = Engram.Native.frontmatter_emit_dirty_nif(pairs)
        assert peak <= 10 * bytes, "#{peak} for #{bytes}"
      end
    end

    test "repeated calls leak nothing" do
      pairs = [{"title", ~s("T: x")}, {"tags", ~s(["a",{"b":null}])}, {"f", "1.5"}, {"x", "bad"}]
      Engram.NativeLeak.assert_no_leak(fn -> Engram.Native.frontmatter_emit_nif(pairs) end)
    end

    test "up to 16 KB renders on the calling scheduler, more goes dirty" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Frontmatter.emit(["a"], %{"a" => Jason.encode!(String.duplicate("x", 16_000))})
      assert_receive {_, ^ref, _, %{nif: :frontmatter_emit, dirty: false}}
      Frontmatter.emit(["a"], %{"a" => Jason.encode!(String.duplicate("x", 17_000))})
      assert_receive {_, ^ref, _, %{nif: :frontmatter_emit, dirty: true}}
    end
  end
end
