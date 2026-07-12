defmodule Engram.Notes.FrontmatterTest do
  use ExUnit.Case, async: true
  alias Engram.Notes.Frontmatter

  describe "split/1" do
    test "extracts the yaml block and body when a well-formed fence is present" do
      assert Frontmatter.split("---\ntitle: Hi\n---\nbody text\n") ==
               {"title: Hi\n", "body text\n"}
    end

    test "returns nil block and full text as body when there is no frontmatter" do
      assert Frontmatter.split("just body\nno fence\n") == {nil, "just body\nno fence\n"}
    end

    test "returns nil block when the closing fence is missing (unrecognized)" do
      assert Frontmatter.split("---\ntitle: Hi\nno close\n") ==
               {nil, "---\ntitle: Hi\nno close\n"}
    end

    test "empty frontmatter yields an empty block, not nil" do
      assert Frontmatter.split("---\n---\nbody\n") == {"", "body\n"}
    end

    test "frontmatter must start at byte 0 (leading blank line means no frontmatter)" do
      assert Frontmatter.split("\n---\ntitle: Hi\n---\nbody\n") ==
               {nil, "\n---\ntitle: Hi\n---\nbody\n"}
    end

    test "closing fence at EOF with no trailing newline" do
      assert Frontmatter.split("---\ntitle: Hi\n---") ==
               {"title: Hi\n", ""}
    end

    test "closing fence with trailing space" do
      assert Frontmatter.split("---\ntitle: Hi\n--- \nbody\n") ==
               {"title: Hi\n", "body\n"}
    end
  end

  describe "parse/1" do
    test "returns ordered keys and JSON-encoded values" do
      assert Frontmatter.parse("title: Hi\ntags:\n  - a\n  - b\n") ==
               {:ok, ["title", "tags"], %{"title" => "\"Hi\"", "tags" => "[\"a\",\"b\"]"}, []}
    end

    test "empty block yields empty order and values" do
      assert Frontmatter.parse("") == {:ok, [], %{}, []}
    end

    test "malformed yaml returns :error" do
      assert Frontmatter.parse("title: : : broken\n  - bad indent\n") == :error
    end

    test "nested map value encodes to JSON, nested keys do not appear in order" do
      result = Frontmatter.parse("meta:\n  author: Todd\n")
      assert result == {:ok, ["meta"], %{"meta" => "{\"author\":\"Todd\"}"}, []}
    end

    test "nested map value uses recursively sorted keys (canonical JSON, matches plugin)" do
      result = Frontmatter.parse("meta:\n  b: 2\n  a: 1\n")
      assert result == {:ok, ["meta"], %{"meta" => "{\"a\":1,\"b\":2}"}, []}
    end

    test "deeply nested map value uses recursively sorted keys at all levels" do
      result = Frontmatter.parse("outer:\n  z:\n    y: 1\n    x: 2\n")
      assert result == {:ok, ["outer"], %{"outer" => "{\"z\":{\"x\":2,\"y\":1}}"}, []}
    end

    test "inline colon in value extracts key correctly" do
      result = Frontmatter.parse("url: https://example.com\n")
      assert result == {:ok, ["url"], %{"url" => "\"https://example.com\""}, []}
    end

    test "bare list (not a map) returns :error" do
      assert Frontmatter.parse("- a\n- b\n") == :error
    end

    test "parse/1 reports degraded keys with snippet + line, keeps good keys" do
      # `date`'s value is a nested map with a non-binary (list) key, which
      # YAML supports (flow complex-key syntax) but JSON cannot express, so
      # encode_values/1 collects it into bad_keys instead of raising.
      block = "tags:\n  - a\ndate: {[a, b]: 1}\n"
      assert {:ok, order, values, degraded} = Frontmatter.parse(block)
      assert "tags" in order
      assert values["tags"] == ~s(["a"])
      # snippet is redacted to the KEY only (never the value): parse_reason is
      # stored PLAINTEXT and echoed on /sync/changes, content is encrypted.
      assert [%{key: "date", snippet: "date:", line: 3}] = degraded
      refute Map.has_key?(values, "date")
    end

    test "parse/1 returns :error only for non-map YAML" do
      assert :error = Frontmatter.parse("just a scalar\n")
    end

    test "parse/1 stays total when a top-level KEY is itself non-binary" do
      # Flow-style complex mapping key: a valid YAML map whose top-level key is
      # a list, not a string. It cannot be JSON-encoded, so it must degrade
      # (not raise) even though degraded_entry can't regex-match a non-binary.
      assert {:ok, _order, values, degraded} = Frontmatter.parse("{[a, b]: 1}: {[c, d]: 2}\n")
      assert values == %{}
      assert [%{key: _, line: nil, snippet: _}] = degraded
    end

    test "parse/1 empty block" do
      assert {:ok, [], %{}, []} = Frontmatter.parse("")
    end

    test "degraded key snippet is REDACTED (key only), never the value, even for a long value" do
      padding = String.duplicate("x", 500)
      block = "tags:\n  - a\ndate: {[#{padding}]: 1}\n"

      assert {:ok, _order, _values, degraded} = Frontmatter.parse(block)
      assert [%{key: "date", line: 3, snippet: snippet}] = degraded
      # No fragment of the value (the padding) appears in the diagnostic.
      assert snippet == "date:"
      refute snippet =~ "x"

      reason = Frontmatter.reason_for(degraded)
      assert reason["detail"]["snippet"] == "date:"
    end
  end

  describe "invalid_yaml_reason/1" do
    test "redacts the block to a generic marker (never the raw block text)" do
      secret = "apikey: sk-super-secret-value"
      reason = Frontmatter.invalid_yaml_reason(secret <> "\n: : :\n")
      assert reason["detail"]["snippet"] == "<frontmatter>"
      refute reason["detail"]["snippet"] =~ "secret"
    end
  end

  describe "emit/2 and self-idempotency" do
    test "emits keys in order and round-trips through parse" do
      order = ["title", "tags"]
      values = %{"title" => "\"Hi\"", "tags" => "[\"a\",\"b\"]"}
      block = Frontmatter.emit(order, values)
      assert {:ok, ^order, ^values, []} = Frontmatter.parse(block)
    end

    test "empty inputs emit an empty string" do
      assert Frontmatter.emit([], %{}) == ""
    end

    test "keys missing from values are silently skipped" do
      order = ["title", "missing_key"]
      values = %{"title" => "\"Hello\""}
      block = Frontmatter.emit(order, values)
      assert {:ok, ["title"], %{"title" => "\"Hello\""}, []} = Frontmatter.parse(block)
    end

    test "nested map value round-trips" do
      order = ["meta"]
      values = %{"meta" => "{\"author\":\"Todd\"}"}
      block = Frontmatter.emit(order, values)
      assert {:ok, ^order, ^values, []} = Frontmatter.parse(block)
    end

    test "emit tolerates a non-JSON string value (degrades to raw string)" do
      out = Frontmatter.emit(["k"], %{"k" => "not json"})
      assert out == "k: not json\n"
    end

    test "degraded non-JSON string round-trips stably" do
      out = Frontmatter.emit(["k"], %{"k" => "not json"})
      {:ok, order, values, []} = Frontmatter.parse(out)
      assert Frontmatter.emit(order, values) == out
    end

    test "emit degrades an unserializable value instead of raising" do
      out = Frontmatter.emit(["k"], %{"k" => {:tuple, :not_yaml}})
      assert out =~ "k:"
    end

    test "emit tolerates a non-binary value" do
      out = Frontmatter.emit(["k"], %{"k" => 42})
      assert out =~ "k:"
    end

    test "emit renders an out-of-band raw passthrough verbatim" do
      order = ["tags", "date"]
      values = %{"tags" => ~s(["a"])}
      raws = %{"date" => "date: {[a, b]: 1}"}
      # Good key emits canonically (Ymlr 2-space list indent); the degraded
      # key's raw source is re-rendered byte-for-byte (never via Ymlr).
      assert Frontmatter.emit(order, values, raws) == "tags:\n  - a\ndate: {[a, b]: 1}\n"
    end

    test "emit renders a MULTI-LINE out-of-band raw passthrough verbatim" do
      raws = %{"date" => "date:\n  [a, b]: 1"}
      assert Frontmatter.emit(["date"], %{}, raws) == "date:\n  [a, b]: 1\n"
    end

    test "emit does NOT interpret a normal value shaped like the old marker" do
      # A real value (a map that merely contains the old marker key) must emit
      # as canonical YAML, not be dropped: raws is the ONLY passthrough source.
      values = %{"mykey" => ~s({"__engram_raw__":"hello"})}
      out = Frontmatter.emit(["mykey"], values)
      assert out =~ "mykey:"
      assert {:ok, ["mykey"], ^values, []} = Frontmatter.parse(out)
    end
  end

  describe "parse_for_ingest/1" do
    test "empty block yields empty order, values, and raws" do
      assert Frontmatter.parse_for_ingest("") == {:ok, [], %{}, %{}}
    end

    test "good-only block behaves like the structured parse path (no raws)" do
      assert Frontmatter.parse_for_ingest("title: Hi\ntags:\n  - a\n") ==
               {:ok, ["title", "tags"], %{"title" => "\"Hi\"", "tags" => "[\"a\"]"}, %{}}
    end

    test "a degraded key is stored out of band (raws) at its source position" do
      assert {:ok, ["tags", "date"], values, raws} =
               Frontmatter.parse_for_ingest("tags:\n  - a\ndate: {[a, b]: 1}\n")

      assert values["tags"] == ~s(["a"])
      refute Map.has_key?(values, "date")
      assert raws["date"] == "date: {[a, b]: 1}"
    end

    test "a MULTI-LINE degraded value captures its full source span out of band" do
      assert {:ok, ["tags", "date"], _values, raws} =
               Frontmatter.parse_for_ingest("tags:\n  - a\ndate:\n  [a, b]: 1\n")

      assert raws["date"] == "date:\n  [a, b]: 1"
    end

    test "returns :error (caller falls back to body) when a degraded key cannot be located" do
      # Non-binary top-level key: valid YAML map, but the degraded key has no
      # column-0 source line, so an exact raw span cannot be guaranteed.
      assert Frontmatter.parse_for_ingest("{[a, b]: 1}: {[c, d]: 2}\n") == :error
    end

    test "non-map YAML returns :error" do
      assert Frontmatter.parse_for_ingest("just a scalar\n") == :error
    end
  end

  describe "encode_values/1 leniency" do
    test "keeps encodable keys and collects the unencodable ones without raising" do
      map = %{"tags" => ["a", "b"], "weird" => {:a, :tuple}}
      assert {values, bad_keys} = Frontmatter.encode_values(map)
      assert values["tags"] == ~s(["a","b"])
      refute Map.has_key?(values, "weird")
      assert bad_keys == ["weird"]
    end

    test "an exotic (charlist/tuple) KEY in a nested map is collected, not raised" do
      # mirrors the yamerl output that 500'd prod (date:YYYY-MM-DD)
      map = %{"date" => %{~c"tag:yaml.org,2002:str" => "x"}}
      assert {values, bad_keys} = Frontmatter.encode_values(map)
      assert bad_keys == ["date"]
      assert values == %{}
    end

    test "all-good map returns empty bad_keys" do
      assert {values, []} = Frontmatter.encode_values(%{"a" => 1, "b" => "s"})
      assert values == %{"a" => "1", "b" => ~s("s")}
    end
  end

  describe "project/3" do
    test "wraps frontmatter in fences and prepends to body" do
      assert Frontmatter.project(["title"], %{"title" => "\"Hi\""}, "body\n") ==
               "---\ntitle: Hi\n---\nbody\n"
    end

    test "empty frontmatter produces body only (no fence)" do
      assert Frontmatter.project([], %{}, "body only\n") == "body only\n"
    end
  end
end
