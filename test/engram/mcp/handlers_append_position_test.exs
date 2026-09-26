defmodule Engram.MCP.HandlersAppendPositionTest do
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes
  alias Engram.Notes.Frontmatter

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put!(u, v, path, content),
    do:
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => path, "content" => content, "mtime" => 1.0})

  defp body(u, v, path) do
    {:ok, note} = Notes.get_note(u, v, path)
    {:ok, c} = Notes.authoritative_content(u, note)
    c
  end

  test "start inserts after the frontmatter fence, frontmatter untouched", %{user: u, vault: v} do
    put!(u, v, "F.md", "---\ntags: [a]\n---\n# F\n\nold\n")
    # The storage pipeline canonicalizes YAML on write (flow -> block style);
    # that happens on the initial put! above, before our code runs. Capture
    # the ACTUAL stored frontmatter as the baseline instead of assuming the
    # original flow-style text survives, so this test only pins what
    # append_to_note itself must not touch: the frontmatter bytes.
    before = body(u, v, "F.md")
    {frontmatter, _rest} = Frontmatter.split(before)

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "F.md",
               "text" => "new",
               "position" => "start"
             })

    assert body(u, v, "F.md") == "---\n" <> frontmatter <> "---\nnew\n# F\n\nold\n"
  end

  test "start with no frontmatter goes to the very top", %{user: u, vault: v} do
    put!(u, v, "P.md", "# P\n\nold\n")

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "P.md",
               "text" => "new",
               "position" => "start"
             })

    assert body(u, v, "P.md") =~ ~r/\Anew\n# P/
  end

  test "start on an empty note becomes the body", %{user: u, vault: v} do
    put!(u, v, "Z.md", "")

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "Z.md",
               "text" => "new",
               "position" => "start"
             })

    assert body(u, v, "Z.md") == "new\n"
  end

  test "default position is still end", %{user: u, vault: v} do
    put!(u, v, "E.md", "# E\n\nold\n")

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{"path" => "E.md", "text" => "new"})

    assert body(u, v, "E.md") =~ ~r/old\nnew\z/
  end

  test "explicit null position behaves as end", %{user: u, vault: v} do
    put!(u, v, "N.md", "# N\n\nold\n")

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "N.md",
               "text" => "new",
               "position" => nil
             })

    assert body(u, v, "N.md") =~ ~r/old\nnew\z/
  end

  test "an unknown position is a fixable error", %{user: u, vault: v} do
    put!(u, v, "X.md", "x")

    assert {:error, msg} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "X.md",
               "text" => "t",
               "position" => "middle"
             })

    assert msg =~ "position must be end or start"
  end

  test "a non-string position is a fixable error", %{user: u, vault: v} do
    put!(u, v, "Y.md", "y")

    assert {:error, msg} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "Y.md",
               "text" => "t",
               "position" => 1
             })

    assert msg =~ "position must be end or start"
  end

  test "position: false is a fixable error, not a silent default to end", %{user: u, vault: v} do
    put!(u, v, "B.md", "# B\n\nold\n")

    assert {:error, msg} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "B.md",
               "text" => "t",
               "position" => false
             })

    assert msg =~ "position must be end or start"
    assert body(u, v, "B.md") == "# B\n\nold\n"
  end

  # Review round 1: place_text builds the note's plaintext, but the doc's Y.Text
  # BODY is what CrdtBridge.ingest_plaintext/2 re-splits on the NEXT write, and
  # what CrdtBridge.normalize_doc/1 re-splits on the NEXT room bind. Verified via
  # Engram.Notes.Frontmatter.split/1 directly (not asserted here, just documented):
  # for text = "---\na: 1\n---\nhi", `text <> "\n" <> body` parses back to
  # {"a: 1\n", "hi\n" <> body} REGARDLESS of whether the original note had
  # frontmatter — so the guard must fire on both paths, not just the no-frontmatter
  # one.
  test "start refuses text that would misparse as frontmatter (no existing frontmatter)", %{
    user: u,
    vault: v
  } do
    put!(u, v, "P2.md", "# P\n\nold\n")

    assert {:error, msg} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "P2.md",
               "text" => "---\na: 1\n---\nhi",
               "position" => "start"
             })

    assert msg =~
             "text would be read as frontmatter at the top of this note; start it with " <>
               "something other than a --- line, or use position end"

    assert body(u, v, "P2.md") == "# P\n\nold\n"
  end

  test "start refuses the same misparse risk even when frontmatter already exists", %{
    user: u,
    vault: v
  } do
    put!(u, v, "F2.md", "---\ntags: [a]\n---\n# F\n\nold\n")
    before = body(u, v, "F2.md")

    assert {:error, msg} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "F2.md",
               "text" => "---\na: 1\n---\nhi",
               "position" => "start"
             })

    assert msg =~ "would be read as frontmatter"
    assert body(u, v, "F2.md") == before
  end

  test "start allows a leading --- that never closes into a parseable frontmatter block", %{
    user: u,
    vault: v
  } do
    put!(u, v, "H.md", "# H\n\nold\n")

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "H.md",
               "text" => "---\nrule",
               "position" => "start"
             })

    assert body(u, v, "H.md") =~ ~r/\A---\nrule\n# H/
  end

  # Pre-merge review finding 3: a note that is ONLY frontmatter with NO
  # trailing newline ("---\ntags: [a]\n---") has an empty body per
  # Frontmatter.split. The old place_text/3 "start" clause built the prefix
  # via `String.replace_suffix(content, body, "")`, which is `content`
  # unchanged when `body` is "" — so text was glued directly onto the closing
  # fence ("---\ntags: [a]\n---hello\n"), and that glued string no longer
  # parses as frontmatter at all on the next read.
  #
  # `Notes.upsert_note/3` re-derives content via the CRDT ingest pipeline,
  # which canonicalizes YAML (flow -> block style) whenever it recognizes
  # frontmatter, so seeding through the normal write path would silently heal
  # this shape before append_to_note ever saw it. `Engram.Fixtures.insert_note!/3`
  # writes the row directly (crdt_state left nil), so `authoritative_content`
  # returns the raw `note.content` bytes untouched (`notes.ex` ~2255) and the
  # no-trailing-newline shape actually reaches `place_text/3`.
  test "start on a frontmatter-only note with no trailing newline keeps the fence parseable", %{
    user: u,
    vault: v
  } do
    Engram.Fixtures.insert_note!(u, v, %{path: "FM.md", content: "---\ntags: [a]\n---"})

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "FM.md",
               "text" => "hello",
               "position" => "start"
             })

    result = body(u, v, "FM.md")
    assert {frontmatter, rest} = Frontmatter.split(result)
    assert frontmatter != nil
    assert String.starts_with?(rest, "hello")
  end

  test "start on a frontmatter-only note WITH a trailing newline is unaffected (empty body)", %{
    user: u,
    vault: v
  } do
    Engram.Fixtures.insert_note!(u, v, %{path: "FM2.md", content: "---\ntags: [a]\n---\n"})

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "FM2.md",
               "text" => "hello",
               "position" => "start"
             })

    result = body(u, v, "FM2.md")
    assert {frontmatter, rest} = Frontmatter.split(result)
    assert frontmatter != nil
    assert String.starts_with?(rest, "hello")
  end
end
