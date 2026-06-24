defmodule Engram.MCP.HandlersGetNoteTest do
  use ExUnit.Case, async: true

  alias Engram.MCP.Handlers

  defp note(attrs) do
    Enum.into(attrs, %{title: "Untitled", tags: [], path: "n.md", folder: "", content: ""})
  end

  describe "format_get_note/1 — metadata de-duplication (#731)" do
    test "a note with frontmatter does not re-inject Title or Tags" do
      content = "---\ntitle: My Note\ntags:\n  - project\n---\n# My Note\n\nBody text."
      out = Handlers.format_get_note(note(title: "My Note", tags: ["project"], content: content))

      assert String.starts_with?(out, "**Path:** n.md"),
             "no injected title/tags before Path block"

      refute String.contains?(out, "**Tags:**"), "Tags should come from frontmatter, not injected"
      assert String.contains?(out, content), "note body must be returned verbatim"
    end

    test "a note opening with an H2 still gets an injected title (## is not an H1)" do
      content = "## Subheading\n\nBody."
      out = Handlers.format_get_note(note(title: "Real Title", tags: [], content: content))

      assert String.starts_with?(out, "# Real Title")
    end

    test "frontmatter without a tags: key still injects inline-derived tags" do
      content = "---\ntitle: T\n---\nBody with #inline"
      out = Handlers.format_get_note(note(title: "T", tags: ["inline"], content: content))

      assert String.contains?(out, "**Tags:** inline")
    end

    test "frontmatter without a title: key still injects the title" do
      content = "---\ntags:\n  - x\n---\nBody."
      out = Handlers.format_get_note(note(title: "Derived", tags: ["x"], content: content))

      assert String.starts_with?(out, "# Derived")
      refute String.contains?(out, "**Tags:**"), "tags live in frontmatter, not injected"
    end

    test "nil tags and nil folder render without crashing" do
      out = Handlers.format_get_note(note(title: "N", tags: nil, folder: nil, content: "plain"))

      assert String.contains?(out, "# N")
      assert String.contains?(out, "**Folder:** \n")
      refute String.contains?(out, "**Tags:**")
    end

    test "a frontmatter-less note keeps the injected Title and Tags" do
      content = "Just a plain body, no frontmatter."
      out = Handlers.format_get_note(note(title: "Plain", tags: ["x"], content: content))

      assert String.contains?(out, "# Plain")
      assert String.contains?(out, "**Tags:** x")
      assert String.contains?(out, content)
    end

    test "a frontmatter-less note that opens with an H1 does not get a duplicate injected title" do
      content = "# Heading\n\nBody."
      out = Handlers.format_get_note(note(title: "Heading", tags: [], content: content))

      # Only the body's own H1 should remain — no injected `# Heading` on top of it.
      assert Enum.count(String.split(out, "\n"), &(&1 == "# Heading")) == 1
    end
  end
end
