defmodule Engram.MCP.HandlersEditNoteTest do
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "N.md",
        "content" => "# N\n\n## Todo\n\na\na\n\n## Done\n\nx\n",
        "mtime" => 1.0
      })

    %{user: user, vault: vault}
  end

  defp body(user, vault) do
    {:ok, note} = Notes.get_note(user, vault, "N.md")
    {:ok, content} = Notes.authoritative_content(user, note)
    content
  end

  test "replace_text replaces the first occurrence", %{user: u, vault: v} do
    assert {:ok, _, %{"replacements" => 1, "mode" => "replace_text"}} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "a",
               "replace" => "b"
             })

    assert body(u, v) =~ "## Todo\n\nb\na"
  end

  test "replace_text refuses when expected_replacements does not match, and writes nothing", %{
    user: u,
    vault: v
  } do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "a",
               "replace" => "b",
               "occurrence" => -1,
               "expected_replacements" => 1
             })

    assert msg =~ "expected 1 replacement(s), found 2"
    assert body(u, v) == before
  end

  test "replace_text accepts old_text/new_text aliases", %{user: u, vault: v} do
    assert {:ok, _, %{"replacements" => 1}} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "old_text" => "x",
               "new_text" => "y"
             })

    assert body(u, v) =~ "## Done\n\ny"
  end

  test "replace_section replaces under the heading only", %{user: u, vault: v} do
    assert {:ok, _, %{"heading" => "Todo", "mode" => "replace_section"}} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_section",
               "heading" => "Todo",
               "content" => "z"
             })

    assert body(u, v) =~ "## Todo\nz\n## Done"
  end

  test "replace_section is not fooled by a # line inside a code fence", %{user: u, vault: v} do
    bt = String.duplicate("`", 3)
    content = "## Todo\n\n#{bt}\n## fake\n#{bt}\nold\n\n## Done\n\nx\n"
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "F.md", "content" => content, "mtime" => 2.0})

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "F.md",
               "mode" => "replace_section",
               "heading" => "Todo",
               "content" => "new"
             })

    {:ok, note} = Notes.get_note(u, v, "F.md")
    {:ok, out} = Notes.authoritative_content(u, note)
    assert out == "## Todo\nnew\n## Done\n\nx\n"
  end

  # Review Focus 1
  test "a parameter from the other mode is a fixable error, not a partial edit", %{
    user: u,
    vault: v
  } do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "a",
               "replace" => "b",
               "heading" => "Todo"
             })

    assert msg =~ "heading is only valid with mode replace_section"
    assert body(u, v) == before
  end

  test "missing mode-required params are named", %{user: u, vault: v} do
    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_section",
               "content" => "z"
             })

    assert msg =~ "heading is required for mode replace_section"
  end

  # Fix round 1, item 1: strict-schema clients (OpenAI strict mode) send every
  # declared property, nulling out the ones they don't use. An explicit null
  # for the other mode's param must not be treated as a stray cross-mode arg.
  test "an explicit null for the other mode's param does not reject replace_text", %{
    user: u,
    vault: v
  } do
    assert {:ok, _, %{"mode" => "replace_text"}} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "a",
               "replace" => "b",
               "heading" => nil,
               "content" => nil,
               "level" => nil
             })
  end

  test "an explicit null for the other mode's param does not reject replace_section", %{
    user: u,
    vault: v
  } do
    assert {:ok, _, %{"mode" => "replace_section"}} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_section",
               "heading" => "Todo",
               "content" => "z",
               "find" => nil,
               "replace" => nil,
               "occurrence" => nil,
               "expected_replacements" => nil,
               "old_text" => nil,
               "new_text" => nil
             })
  end

  # Fix round 1, item 2: "" passes is_binary, and do_replace/4 happily
  # prepends (occurrence 0) or interleaves (occurrence -1) empty-string
  # "replacements" while reporting success. Must fail closed instead.
  test "an empty find is refused without writing", %{user: u, vault: v} do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "",
               "replace" => "y"
             })

    assert msg =~ "find must not be empty for mode replace_text"
    assert body(u, v) == before
  end

  test "a non-string find names itself rather than saying it is required", %{user: u, vault: v} do
    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => 123,
               "replace" => "b"
             })

    assert msg == "find must be a string"
  end

  test "a text param present under replace_section is a fixable error, not a partial edit", %{
    user: u,
    vault: v
  } do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_section",
               "heading" => "Todo",
               "content" => "z",
               "find" => "a"
             })

    assert msg =~ "find is only valid with mode replace_text"
    assert body(u, v) == before
  end

  test "old_text present under replace_section is a fixable error, not a partial edit", %{
    user: u,
    vault: v
  } do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_section",
               "heading" => "Todo",
               "content" => "z",
               "old_text" => "a"
             })

    assert msg =~ "old_text is only valid with mode replace_text"
    assert body(u, v) == before
  end

  test "an invalid mode is a fixable error", %{user: u, vault: v} do
    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "bogus",
               "find" => "a",
               "replace" => "b"
             })

    assert msg =~ "mode must be replace_text, replace_section or insert_section"
  end

  test "occurrence past the last one is not found, via edit_note", %{user: u, vault: v} do
    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "a",
               "replace" => "b",
               "occurrence" => 5
             })

    assert msg =~ "Occurrence 5 not found in N.md"
  end

  test "a heading not found is reported, via edit_note", %{user: u, vault: v} do
    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_section",
               "heading" => "Nonexistent",
               "content" => "z"
             })

    assert msg =~ "Heading not found"
  end

  # Pre-merge review finding 1: occurrence has no schema minimum, so -2
  # reaches do_replace/4's second clause, which does
  # `Enum.take(parts, occurrence + 1)` — a NEGATIVE count, which Enum.take
  # silently reads from the END of the list instead of refusing. patch_note
  # shares patch_text/6 with edit_note (`patch_note` calls it directly,
  # bypassing run_edit's cond entirely), so the guard belongs in patch_text
  # itself, not in run_edit, or the alias stays exposed.
  test "occurrence below -1 is refused without writing, via edit_note", %{user: u, vault: v} do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "a",
               "replace" => "b",
               "occurrence" => -2
             })

    assert msg =~ "occurrence must be -1 (all) or 0 or greater"
    assert body(u, v) == before
  end

  test "occurrence below -1 is refused without writing, via patch_note", %{user: u, vault: v} do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("patch_note", u, v, %{
               "path" => "N.md",
               "find" => "a",
               "replace" => "b",
               "occurrence" => -2
             })

    assert msg =~ "occurrence must be -1 (all) or 0 or greater"
    assert body(u, v) == before
  end

  # Pre-merge review finding 2: replace_section clamps the heading-match
  # prefix to level 1..6 (`max(1, min(level, 6))`) but the section-END scan
  # compares against the RAW `level`, so level 0 (or > 6) never satisfies
  # `h_level <= level` for any real heading and the section "end" is never
  # found, swallowing every following section. The guard must reject the
  # level outright, before any heading search runs, so it fires regardless
  # of whether a heading would even match.
  test "level outside 1..6 is refused without writing, via edit_note", %{user: u, vault: v} do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_section",
               "heading" => "Todo",
               "content" => "z",
               "level" => 0
             })

    assert msg =~ "level must be between 1 and 6"
    assert body(u, v) == before
  end

  test "level outside 1..6 is refused without writing, via update_section", %{user: u, vault: v} do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("update_section", u, v, %{
               "path" => "N.md",
               "heading" => "Todo",
               "content" => "z",
               "level" => 7
             })

    assert msg =~ "level must be between 1 and 6"
    assert body(u, v) == before
  end

  # Pre-merge review finding 4: the `find == ""` guard lived only in
  # run_edit's cond, so patch_note (which calls patch_text/6 directly) never
  # saw it and could still corrupt the note via an always-matching empty find.
  test "an empty find is refused without writing, via patch_note", %{user: u, vault: v} do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("patch_note", u, v, %{
               "path" => "N.md",
               "find" => "",
               "replace" => "y"
             })

    assert msg =~ "find must not be empty"
    assert body(u, v) == before
  end

  # Review round 2, finding 1: a closing fence may not carry an info string.
  # "```js" inside an already-open fence must not close it, or replace_section
  # deletes everything up to and including the NEXT heading it wrongly sees
  # as still "inside" the (falsely-reopened) fence region.
  test "replace_section on a fence whose closer carries an info string does not delete the next section",
       %{user: u, vault: v} do
    content = "## A\n```\n```js\n```\n## B\nkeep\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Fence2.md", "content" => content, "mtime" => 3.0})

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "Fence2.md",
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    {:ok, note} = Notes.get_note(u, v, "Fence2.md")
    {:ok, out} = Notes.authoritative_content(u, note)
    assert out == "## A\nnew\n## B\nkeep\n"
  end

  # Review round 2, finding 3: replace_section must not mix line endings when
  # rewriting a CRLF note.
  test "replace_section keeps the note's CRLF line endings uniform", %{user: u, vault: v} do
    content = "## A\r\nold\r\n## B\r\nkeep\r\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Crlf.md", "content" => content, "mtime" => 4.0})

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "Crlf.md",
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "n1\nn2"
             })

    {:ok, note} = Notes.get_note(u, v, "Crlf.md")
    {:ok, out} = Notes.authoritative_content(u, note)
    assert out == "## A\r\nn1\r\nn2\r\n## B\r\nkeep\r\n"
  end

  # Review round 2, finding 4: a setext heading occupies two lines; replacing
  # its section must keep BOTH the paragraph text and the underline.
  test "replace_section on a setext heading keeps the underline line", %{user: u, vault: v} do
    content = "Title\n=====\n\nold\n\nNext\n====\n\nz\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Setext.md", "content" => content, "mtime" => 5.0})

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "Setext.md",
               "mode" => "replace_section",
               "heading" => "Title",
               "level" => 1,
               "content" => "new"
             })

    {:ok, note} = Notes.get_note(u, v, "Setext.md")
    {:ok, out} = Notes.authoritative_content(u, note)
    assert out == "Title\n=====\nnew\nNext\n====\n\nz\n"
  end

  # Fix round 2, Important: a list item followed by a thematic break must not
  # be read as a setext heading; replace_section on the PRECEDING heading
  # must replace through both lines, leaving no stale "- item" behind.
  test "replace_section on A drops a trailing list item and thematic break, not just up to them",
       %{user: u, vault: v} do
    content = "## A\n- item\n---\n## B\nb\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "List.md", "content" => content, "mtime" => 6.0})

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "List.md",
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    {:ok, note} = Notes.get_note(u, v, "List.md")
    {:ok, out} = Notes.authoritative_content(u, note)
    assert out == "## A\nnew\n## B\nb\n"
  end

  # Fix round 2, Minor 3: replace_section to end of file on a CRLF note with
  # no trailing newline must not leave a bare LF or a stray trailing CR.
  test "replace_section to end of file on a CRLF note with no trailing newline stays uniform", %{
    user: u,
    vault: v
  } do
    content = "## A\r\nold"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "CrlfEof.md", "content" => content, "mtime" => 7.0})

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "CrlfEof.md",
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "n1\nn2"
             })

    {:ok, note} = Notes.get_note(u, v, "CrlfEof.md")
    {:ok, out} = Notes.authoritative_content(u, note)
    assert out == "## A\r\nn1\r\nn2"
  end

  # Fix round 4 (final), data-loss repro: a "%%" inside an inline code span
  # must not "open" an Obsidian comment that swallows a later section.
  test "replace_section on A keeps a later section that follows a code-span %%", %{
    user: u,
    vault: v
  } do
    content = "## A\nUse `%%` to hide text in Obsidian.\n\n## B\nkeep me\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "CodeSpan.md", "content" => content, "mtime" => 8.0})

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "CodeSpan.md",
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    {:ok, note} = Notes.get_note(u, v, "CodeSpan.md")
    {:ok, out} = Notes.authoritative_content(u, note)
    assert out == "## A\nnew\n## B\nkeep me\n"
  end

  # Fix round 4, defense in depth: a GENUINE unclosed comment must refuse the
  # edit rather than silently deleting (replace_section) or misplacing
  # (insert_section end) whatever follows it.
  test "replace_section refuses and writes nothing when the section runs into an unclosed comment",
       %{user: u, vault: v} do
    content = "## A\n%%\nunclosed\n\n## B\nkeep\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Unclosed.md", "content" => content, "mtime" => 9.0})

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "Unclosed.md",
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    assert msg =~ "may run past line 5, which looks like a heading but is hidden"

    {:ok, note} = Notes.get_note(u, v, "Unclosed.md")
    {:ok, out} = Notes.authoritative_content(u, note)
    assert out == content
  end

  test "insert_section position end refuses and writes nothing when the section runs into an unclosed comment",
       %{user: u, vault: v} do
    content = "## A\n%%\nunclosed\n\n## B\nkeep\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Unclosed2.md", "content" => content, "mtime" => 10.0})

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "Unclosed2.md",
               "mode" => "insert_section",
               "heading" => "A",
               "position" => "end",
               "content" => "n1"
             })

    assert msg =~ "may run past line 5, which looks like a heading but is hidden"

    {:ok, note} = Notes.get_note(u, v, "Unclosed2.md")
    {:ok, out} = Notes.authoritative_content(u, note)
    assert out == content
  end

  # M1: replacing the LAST section of a note that ends with a newline must
  # keep that final newline (CRLF: no stray "\r" left behind either).
  test "replace_section on the last section of a CRLF note keeps the final CRLF", %{
    user: u,
    vault: v
  } do
    {:ok, _} =
      Notes.upsert_note(u, v, %{
        "path" => "Last.md",
        "content" => "## A\r\nold\r\n",
        "mtime" => 11.0
      })

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "Last.md",
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "NEW"
             })

    {:ok, note} = Notes.get_note(u, v, "Last.md")
    assert {:ok, "## A\r\nNEW\r\n"} = Notes.authoritative_content(u, note)
  end

  test "replace_section on the last section of an LF note keeps the final newline", %{
    user: u,
    vault: v
  } do
    {:ok, _} =
      Notes.upsert_note(u, v, %{
        "path" => "LastLf.md",
        "content" => "## A\nold\n",
        "mtime" => 12.0
      })

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "LastLf.md",
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "NEW"
             })

    {:ok, note} = Notes.get_note(u, v, "LastLf.md")
    assert {:ok, "## A\nNEW\n"} = Notes.authoritative_content(u, note)
  end

  # A section that reaches EOF only because an unclosed code fence swallowed
  # the next heading: refuse, write nothing.
  test "replace_section refuses and writes nothing when the section runs into an unclosed fence",
       %{user: u, vault: v} do
    fence = String.duplicate("`", 3)
    content = "## A\n1. step\n   #{fence}bash\n   run\n#{fence}\n## B\nimportant\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Fence.md", "content" => content, "mtime" => 13.0})

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "Fence.md",
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    assert msg =~ "may run past line 6, which looks like a heading but is hidden"

    {:ok, note} = Notes.get_note(u, v, "Fence.md")
    assert {:ok, ^content} = Notes.authoritative_content(u, note)
  end

  test "insert_section position end refuses when the section runs into an unclosed fence",
       %{user: u, vault: v} do
    fence = String.duplicate("`", 3)
    content = "## A\n#{fence}\n## B\nimportant\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Fence2.md", "content" => content, "mtime" => 14.0})

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "Fence2.md",
               "mode" => "insert_section",
               "heading" => "A",
               "position" => "end",
               "content" => "n1"
             })

    assert msg =~ "may run past line 3, which looks like a heading but is hidden"

    {:ok, note} = Notes.get_note(u, v, "Fence2.md")
    assert {:ok, ^content} = Notes.authoritative_content(u, note)
  end

  # C1 end to end: the "## B" after a comment closed by a backticked "-->"
  # must survive a replace of A.
  test "replace_section on A keeps B after an HTML comment closed inside backticks", %{
    user: u,
    vault: v
  } do
    content = "## A\nbody\n<!--\na `-->` b\n## B\nimportant\n<!-- c -->\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "C1.md", "content" => content, "mtime" => 15.0})

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "C1.md",
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    {:ok, note} = Notes.get_note(u, v, "C1.md")

    assert {:ok, "## A\nnew\n## B\nimportant\n<!-- c -->\n"} =
             Notes.authoritative_content(u, note)
  end

  # --- Fix round (adversarial) ---

  defp edit(u, v, path, args),
    do: Handlers.handle("edit_note", u, v, Map.put(args, "path", path))

  defp put!(u, v, path, content) do
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => path, "content" => content, "mtime" => 20.0})
    content
  end

  defp read!(u, v, path) do
    {:ok, note} = Notes.get_note(u, v, path)
    {:ok, out} = Notes.authoritative_content(u, note)
    out
  end

  # F1: an unclosed <pre> used to make replace_section delete "## B".
  test "replace_section refuses when an unclosed HTML block hides the next heading", %{
    user: u,
    vault: v
  } do
    content = put!(u, v, "Pre.md", "## A\n<pre>\ncode\n## B\nimportant\n")

    assert {:error, msg} =
             edit(u, v, "Pre.md", %{
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    assert msg =~ "may run past line 4"
    assert read!(u, v, "Pre.md") == content
  end

  # F2 end to end.
  test "replace_section refuses when mis-paired %% marks hide the next heading", %{
    user: u,
    vault: v
  } do
    content = put!(u, v, "Pct.md", "## A\n%% note ` %% and `y`\n## B\nimportant\n%% c2 %%\n")

    assert {:error, _} =
             edit(u, v, "Pct.md", %{
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    assert read!(u, v, "Pct.md") == content
  end

  test "replace_section still edits across a closed fence holding # lines", %{user: u, vault: v} do
    fence = String.duplicate("`", 3)
    put!(u, v, "Closed.md", "## A\n#{fence}bash\n## x\n#{fence}\n## B\nkeep\n")

    assert {:ok, _, _} =
             edit(u, v, "Closed.md", %{
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    assert read!(u, v, "Closed.md") == "## A\nnew\n## B\nkeep\n"
  end

  # F3: main edited the plain heading; the rendered-text match must not
  # steal it for the bold one.
  test "replace_section picks the plain heading over one that renders the same", %{
    user: u,
    vault: v
  } do
    put!(u, v, "Two.md", "## **A**\nx\n## A\ny\n")

    assert {:ok, _, _} =
             edit(u, v, "Two.md", %{
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    assert read!(u, v, "Two.md") == "## **A**\nx\n## A\nnew\n"
  end

  test "an ambiguous rendered heading refuses both section modes and writes nothing", %{
    user: u,
    vault: v
  } do
    content = put!(u, v, "Amb.md", "## **A**\nx\n## *A*\ny\n")

    for args <- [
          %{"mode" => "replace_section", "heading" => "A", "content" => "n"},
          %{"mode" => "insert_section", "heading" => "A", "content" => "n"}
        ] do
      assert {:error, "Heading 'A' matches several headings; pass the exact heading text"} =
               edit(u, v, "Amb.md", args)
    end

    assert read!(u, v, "Amb.md") == content
  end

  test "insert_section and update_section work on a note over 1 MB", %{user: u, vault: v} do
    x = String.duplicate("x", 1_200_000)
    put!(u, v, "Big2.md", "## A\n" <> x <> "\n## B\nb\n")

    assert {:ok, _, _} =
             edit(u, v, "Big2.md", %{
               "mode" => "insert_section",
               "heading" => "A",
               "position" => "end",
               "content" => "tail"
             })

    assert read!(u, v, "Big2.md") == "## A\n" <> x <> "\ntail\n## B\nb\n"

    assert {:ok, _, _} =
             Handlers.handle("update_section", u, v, %{
               "path" => "Big2.md",
               "heading" => "B",
               "content" => "new"
             })

    assert read!(u, v, "Big2.md") == "## A\n" <> x <> "\ntail\n## B\nnew\n"
  end

  test "a section edit past the deadline refuses and writes nothing", %{user: u, vault: v} do
    content = put!(u, v, "Dl.md", "## A\nold\n## B\nb\n")
    g = start_supervised!({Engram.MCP.ParseGate, name: nil, limit: 1, max_waiting: 4})
    test = self()

    Task.start(fn ->
      Engram.MCP.ParseGate.run(
        fn ->
          send(test, {:holding, self()})
          receive do: (:go -> :ok)
        end,
        gate: g,
        parse_timeout: :infinity
      )
    end)

    assert_receive {:holding, w}, 5_000
    Process.put(:engram_parse_gate_opts, gate: g, deadline_ms: 50)

    for args <- [
          %{"mode" => "replace_section", "heading" => "A", "content" => "n"},
          %{"mode" => "insert_section", "heading" => "A", "content" => "n"}
        ] do
      assert {:error, msg} = edit(u, v, "Dl.md", args)
      assert msg =~ "ran out of time"
    end

    send(w, :go)
    assert read!(u, v, "Dl.md") == content
  end

  test "section edits work on a note over 1 MB (no size cap)", %{user: u, vault: v} do
    put!(u, v, "Big.md", "## A\n" <> String.duplicate("x", 1_200_000) <> "\n## B\nb\n")

    assert {:ok, _, _} =
             edit(u, v, "Big.md", %{
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "n"
             })

    assert read!(u, v, "Big.md") == "## A\nn\n## B\nb\n"
  end

  # Fix round 2: a hidden setext heading used to be deleted by replace_section.
  test "replace_section refuses when a hidden setext heading follows", %{user: u, vault: v} do
    content = put!(u, v, "Setext.md", "## A\n%% note ` %% and `y`\nB\n---\nimportant\n%% c2 %%\n")

    assert {:error, msg} =
             edit(u, v, "Setext.md", %{
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    assert msg =~ "may run past line 3"
    assert read!(u, v, "Setext.md") == content
  end

  test "replace_section still edits up to a real setext heading", %{user: u, vault: v} do
    put!(u, v, "RealSetext.md", "## A\nold\n\nB\n---\nkeep\n")

    assert {:ok, _, _} =
             edit(u, v, "RealSetext.md", %{
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    assert read!(u, v, "RealSetext.md") == "## A\nnew\nB\n---\nkeep\n"
  end

  test "replace_section keeps the next section after a $$ math block", %{user: u, vault: v} do
    put!(u, v, "Math.md", "## A\n$$\n## x\n$$\nkeep\n## B\nb\n")

    assert {:ok, _, _} =
             edit(u, v, "Math.md", %{
               "mode" => "replace_section",
               "heading" => "A",
               "content" => "new"
             })

    assert read!(u, v, "Math.md") == "## A\nnew\n## B\nb\n"
  end
end
