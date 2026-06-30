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
  end
end
