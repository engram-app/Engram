defmodule Engram.Links.QualifiedTest do
  # `Links.qualified?/1`: the ONE rule for "this link names its target by
  # path" (O(1) folder rename plan S4.6, Engram#2523). `note_links.qualified`
  # stores it, and the rename rewrite's form rule (`Rewriter`) reads it for
  # the path half. It covers path-WRITTEN links only: a bare link whose
  # moved target's basename collides with another live row is rewritten too
  # (`collision?`), so S5 needs a separate collision check
  # (`QualifiedWriterTest` pins that case).
  use ExUnit.Case, async: true

  alias Engram.Links
  alias Engram.Links.Parser

  # The parsed target of the only link in `content`.
  defp qualified(content) do
    assert [link] = Parser.extract(content)
    Links.qualified?(link.target)
  end

  test "a bare wikilink is not qualified" do
    refute qualified("see [[Note]]")
    refute qualified("see [[Note.md]]")
  end

  test "a folder-qualified wikilink is" do
    assert qualified("see [[Folder/Note]]")
    assert qualified("see [[a/b/Note.md]]")
  end

  test "relative and root-anchored paths are qualified" do
    assert qualified("see [[../Note]]")
    assert qualified("see [[./Note]]")
    assert qualified("see [[/Note]]")
  end

  test "embeds follow the same rule" do
    refute qualified("![[image.png]]")
    assert qualified("![[assets/image.png]]")
  end

  test "a slash in the alias or heading does not qualify a bare target" do
    refute qualified("[[Note|a/b]]")
    refute qualified("[[Note#a/b]]")
    refute qualified("[[Note#h|x/y]]")
    assert qualified("[[Folder/Note#Heading|alias]]")
  end

  test "markdown links: a decoded folder qualifies, a bare file does not" do
    refute qualified("[x](Note.md)")
    assert qualified("[x](Folder/Note.md)")
    assert qualified("[x](../Note.md)")
    # Percent-encoded slash: the rule reads the DECODED target, as resolution does.
    assert qualified("[x](Folder%2FNote.md)")
    refute qualified("[x](My%20Note.md)")
  end

  test "case does not matter" do
    refute qualified("[[NOTE]]")
    assert qualified("[[FOLDER/NOTE]]")
  end

  test "an empty target (a same-note heading link) is not qualified" do
    refute Links.qualified?("")
  end
end
