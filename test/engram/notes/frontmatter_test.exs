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
               {:ok, ["title", "tags"], %{"title" => "\"Hi\"", "tags" => "[\"a\",\"b\"]"}}
    end

    test "empty block yields empty order and values" do
      assert Frontmatter.parse("") == {:ok, [], %{}}
    end

    test "malformed yaml returns :error" do
      assert Frontmatter.parse("title: : : broken\n  - bad indent\n") == :error
    end

    test "nested map value encodes to JSON, nested keys do not appear in order" do
      result = Frontmatter.parse("meta:\n  author: Todd\n")
      assert result == {:ok, ["meta"], %{"meta" => "{\"author\":\"Todd\"}"}}
    end

    test "inline colon in value extracts key correctly" do
      result = Frontmatter.parse("url: https://example.com\n")
      assert result == {:ok, ["url"], %{"url" => "\"https://example.com\""}}
    end

    test "bare list (not a map) returns :error" do
      assert Frontmatter.parse("- a\n- b\n") == :error
    end
  end

  describe "encode_values/1" do
    # Route: YamlElixir special floats (.nan/.inf) are parsed to atoms, which
    # Jason encodes as strings, so they do NOT trigger an encode error. The
    # encode-failure branch is tested directly via a map containing a tuple
    # value, which is unencodable by the Jason.Encoder protocol.
    test "returns :error when a value is unencodable (e.g. a tuple)" do
      assert Frontmatter.encode_values(%{"key" => {:not, :encodable}}) == :error
    end

    test "returns {:ok, values_map} when all values are encodable" do
      assert Frontmatter.encode_values(%{"a" => 1, "b" => "hello"}) ==
               {:ok, %{"a" => "1", "b" => "\"hello\""}}
    end
  end
end
