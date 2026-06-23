defmodule Engram.Notes.HelpersTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.Helpers

  # ---------------------------------------------------------------------------
  # extract_title/2
  # ---------------------------------------------------------------------------

  describe "extract_title/2" do
    test "from frontmatter title field" do
      content = "---\ntitle: My Custom Title\n---\n# Heading\nBody"
      assert Helpers.extract_title(content, "Notes/File.md") == "My Custom Title"
    end

    test "from first h1 heading" do
      content = "# My Heading\nBody text"
      assert Helpers.extract_title(content, "Notes/File.md") == "My Heading"
    end

    test "heading with extra spaces stripped" do
      content = "#   Spaced Heading  \nBody"
      assert Helpers.extract_title(content, "Notes/File.md") == "Spaced Heading"
    end

    test "falls back to filename without extension" do
      content = "Just body text, no heading"
      assert Helpers.extract_title(content, "Notes/My Note.md") == "My Note"
    end

    test "filename without folder" do
      assert Helpers.extract_title("Just body text", "Inbox.md") == "Inbox"
    end

    test "frontmatter title takes priority over heading" do
      content = "---\ntitle: FM Title\n---\n# Heading Title\nBody"
      assert Helpers.extract_title(content, "Notes/File.md") == "FM Title"
    end

    test "empty content uses filename" do
      assert Helpers.extract_title("", "Notes/Empty.md") == "Empty"
    end

    test "frontmatter without title falls back to heading" do
      content = "---\ntags: [a, b]\n---\n# The Heading\nBody text"
      assert Helpers.extract_title(content, "Notes/Tagged.md") == "The Heading"
    end

    test "frontmatter without title and no heading uses filename" do
      content = "---\ntags: [a, b]\n---\nBody text"
      assert Helpers.extract_title(content, "Notes/Tagged.md") == "Tagged"
    end
  end

  # ---------------------------------------------------------------------------
  # extract_tags/1
  # ---------------------------------------------------------------------------

  describe "extract_tags/1" do
    test "list-style tags" do
      content = "---\ntags: [health, fitness]\n---\nBody"
      assert Helpers.extract_tags(content) == ["health", "fitness"]
    end

    test "comma-separated string tags" do
      content = "---\ntags: health, fitness\n---\nBody"
      assert Helpers.extract_tags(content) == ["health", "fitness"]
    end

    test "no frontmatter returns empty list" do
      assert Helpers.extract_tags("# No Tags\nBody") == []
    end

    test "empty tags list" do
      content = "---\ntags: []\n---\nBody"
      assert Helpers.extract_tags(content) == []
    end

    test "empty content returns empty list" do
      assert Helpers.extract_tags("") == []
    end

    test "frontmatter without tags field" do
      content = "---\ntitle: Just a title\n---\nBody"
      assert Helpers.extract_tags(content) == []
    end

    test "extracts an inline #tag from the body" do
      assert Helpers.extract_tags("Some body with a #fitness tag") == ["fitness"]
    end

    test "extracts a nested inline #area/sub tag" do
      assert Helpers.extract_tags("Work note #area/subarea here") == ["area/subarea"]
    end

    test "merges frontmatter tags with inline tags, frontmatter first, deduped" do
      content = "---\ntags: [health]\n---\nBody #fitness and again #health"
      assert Helpers.extract_tags(content) == ["health", "fitness"]
    end

    test "skips #tags inside a fenced code block" do
      content = "Intro #real\n\n```\nnot a #tag here\n```\n\nOutro"
      assert Helpers.extract_tags(content) == ["real"]
    end

    test "skips #tags inside an inline code span" do
      content = "Use `#notatag` in code but #realtag in prose"
      assert Helpers.extract_tags(content) == ["realtag"]
    end

    test "skips the # fragment in a URL" do
      content = "See https://example.com/docs#section for details"
      assert Helpers.extract_tags(content) == []
    end

    test "does not treat a word-attached hash as a tag" do
      assert Helpers.extract_tags("issue C#sharp note") == []
    end

    test "skips heading markers" do
      content = "# Heading One\n## Heading Two\nBody #onlytag"
      assert Helpers.extract_tags(content) == ["onlytag"]
    end

    test "rejects purely-numeric matches like #42" do
      assert Helpers.extract_tags("Closes #42 and tags #bug") == ["bug"]
    end

    test "deduplicates repeated inline tags" do
      assert Helpers.extract_tags("#dup once #dup twice") == ["dup"]
    end
  end

  # ---------------------------------------------------------------------------
  # extract_folder/1
  # ---------------------------------------------------------------------------

  describe "extract_folder/1" do
    test "single folder level" do
      assert Helpers.extract_folder("Notes/File.md") == "Notes"
    end

    test "nested folder" do
      assert Helpers.extract_folder("Notes/Sub/File.md") == "Notes/Sub"
    end

    test "no folder returns empty string" do
      assert Helpers.extract_folder("File.md") == ""
    end

    test "deep nesting" do
      assert Helpers.extract_folder("A/B/C/D/File.md") == "A/B/C/D"
    end
  end
end
