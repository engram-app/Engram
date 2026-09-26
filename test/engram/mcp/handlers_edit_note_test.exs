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

    assert msg =~ "mode must be replace_text or replace_section"
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
end
