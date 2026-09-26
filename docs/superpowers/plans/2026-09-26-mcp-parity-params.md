# MCP Parity Params Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close five Obsidian-parity gaps as parameters on existing MCP tools: `edit_note` mode `insert_section`, `search_notes(similar_to)`, `search_notes` with no query lists recent notes, `get_notes(include_links)`, and `get_notes(section | outline)`.

**Architecture:** One new pure module, `Engram.MCP.Sections`, owns heading lookup (frontmatter- and code-fence-aware) for every section feature: `replace_section` is moved onto it, `insert_section` and `get_notes(section | outline)` are built on it. `similar_to` reuses the source note's stored chunk points through Qdrant's Query API `recommend` (strategy `average_vector`) via a new `Search.similar/4` that shares `Search.search/4`'s pipeline minus the embed and the budget spend. Recent notes and links are plain Postgres reads (`Notes.list_recent_notes/3`, the existing `Links.backlinks_for_note/2` and `Links.links_for_note/2`).

**Tech Stack:** Elixir 1.17 / Phoenix, ExUnit + Mox + Bypass, Qdrant 1.17 Query API, Python e2e harness, `mcp-tdqs@0.2.0` (npx).

**Spec:** GitHub issue engram-app/Engram#1793 (binding scope and constraints; `gh issue view 1793 -R engram-app/Engram`). Absorbs and extends Phase 4 (tasks 4.1, 4.2) of `docs/superpowers/plans/2026-09-25-mcp-tool-surface.md`. Parity research: engram-app/Engram#1767, last comment.

## Global Constraints

- Run every `mix` command and every `git push` through `mise exec --` (PATH erl is OTP 26, CI is OTP 27).
- Branch is `feat/mcp-parity-params` (the `feat/` prefix is on the verify.yml allowlist). One PR for the whole plan.
- NO version bumps in `mix.exs`, `server.json` or anywhere: release-please owns versions.
- Conventional commits; PR title `feat(mcp): parity params for search, read and edit`.
- No em dashes in any user-facing text (tool descriptions, schema descriptions, error messages). `tools_descriptions_test.exs` enforces it for the wire list.
- TDD: failing test first, watch it fail, then implement. Never loosen or delete an existing assertion to go green; if one encodes behavior this plan intentionally changes, replace it with an assertion of the new behavior and say so in the commit body.
- Explicit `null` on every new optional parameter behaves exactly as if the key were absent (strict-schema clients send every declared property). Test it where the parameter is added.
- Every new parameter is declared in the tool's `inputSchema` (the controller's `validate_tool_args/2` rejects undeclared keys). The controller checks only JSON types, not enums, so handlers validate enum values themselves.
- Tool descriptions name only listed tools. Tool count stays exactly 17 (`tools_aliases_test.exs` asserts it).
- Any task that changes `lib/engram/mcp/tools.ex` regenerates the snapshot in the same commit: `mise exec -- mix engram.mcp.tools_json`. CI fails on a stale `mcp-tools.json`.
- TDQS lint must be clean: `npx -y mcp-tdqs@0.2.0 lint --file mcp-tools.json --server-name engram --fail-on warning`.
- All writes go through the existing save path (`Notes.upsert_note/4` via `rmw_upsert/5` or the existing `replace_section` upsert) so the separately built history system captures them with no change.
- Annotations stay honest and unchanged: `search_notes` and `get_notes` read-only, `edit_note` destructive.
- Before the push: `mise exec -- mix format`, `mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix credo --strict`, `mise exec -- mix dialyzer`, and the touched test files.

## Review Focus

1. **`insert_section` with `position: end` on the LAST section, and on a heading that has nested subheadings.** Expect the text after the section's last non-blank line (after the subsections, before the next same-or-higher heading), and on the last section the file still ends with its trailing newline. Tests owned by Task 1 (pure) and Task 2 (through the handler).
2. **`similar_to` on a note with no dense vectors yet** (new, empty, sparse-only because the embed budget was spent, or past the index cap). Expect a fixable `isError` naming the path and suggesting `query`, never a crash, a Qdrant 400, or an empty success that reads as "nothing is similar". Test owned by Task 6.
3. **`search_notes` with `query` absent, `""`, whitespace-only, or `null`.** Expect the recent listing with zero embedder calls (Mox expectation of 0) and no budget spend (succeeds under an `ai_searches_per_day` override of 0, while a control `Search.search/4` under the same override is refused). Test owned by Task 5.
4. **`include_links` when another vault of the same user holds a note linking to a same-named target.** Expect no backlink from the other vault, and the other vault's link reported as unresolved there. Test owned by Task 4.
5. **`section` / `outline` / section edits on notes with frontmatter containing `# comment` lines and code fences containing `#` lines.** Expect neither to be treated as a heading, and a section never to end inside a code fence. Tests owned by Task 1 (pure) and Task 3 (through `get_notes`).

---

## File Structure

- Create `lib/engram/mcp/sections.ex`: pure heading scan (`headings/1`), lookup (`find/3`), read (`section/2`), insert (`insert/5`).
- Modify `lib/engram/mcp/handlers.ex`: `replace_section/7` on `Sections`; `insert_section` mode; `get_notes` section/outline/links; `search_notes` recent and similar branches.
- Modify `lib/engram/mcp/tools.ex`: schemas and descriptions for `edit_note`, `get_notes`, `search_notes`.
- Modify `lib/engram/notes.ex`: add `list_recent_notes/3`.
- Modify `lib/engram/indexing.ex`: extract public `point_ids_for_note/1` from `delete_points_for_note/1`.
- Modify `lib/engram/vector/qdrant.ex`: add `recommend/3` and `recommend_body/2`.
- Modify `lib/engram/search.ex`: add `similar/4`, a `:similar` leg, no rerank for a non-text query.
- Tests: `test/engram/mcp/sections_test.exs`, `handlers_insert_section_test.exs`, `handlers_partial_read_test.exs`, `handlers_links_test.exs`, `handlers_recent_test.exs`, `handlers_similar_test.exs`, `test/engram/notes_recent_test.exs`, `test/engram/vector/qdrant_recommend_test.exs`, `e2e/tests/api_only/test_100_mcp_parity_params.py`.

---

### Task 1: Shared section finder, fence- and frontmatter-aware

**Files:**
- Create: `lib/engram/mcp/sections.ex`
- Modify: `lib/engram/mcp/handlers.ex` (`replace_section/7`, currently at ~:773, keep the level guard clause above it)
- Test: `test/engram/mcp/sections_test.exs` (new)

**Interfaces:**
- Produces:
  - `Engram.MCP.Sections.headings(content :: String.t()) :: [%{line: non_neg_integer(), level: 1..6, text: String.t()}]` (`line` indexes `String.split(content, "\n")`)
  - `Engram.MCP.Sections.find(content, heading :: String.t(), level :: 1..6 | nil) :: {:ok, %{start: non_neg_integer(), stop: non_neg_integer()}} | :error` (`start` = heading line, `stop` = exclusive end: next heading with level <= the matched level, or line count; `level: nil` matches any level, first match wins)
  - `Engram.MCP.Sections.section(content, heading) :: {:ok, String.t()} | :error` (heading line included, trailing blank lines trimmed, any level)
  - `Engram.MCP.Sections.insert(content, heading, level, position :: "start" | "end", text) :: {:ok, String.t()} | :error`

Behavior change, deliberate: `replace_section` (and its hidden alias `update_section`) no longer matches a heading-looking line inside a code fence or frontmatter, and a section no longer ends at a `# comment` line inside a fence. Existing `replace_section` tests keep passing unchanged.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/mcp/sections_test.exs
defmodule Engram.MCP.SectionsTest do
  use ExUnit.Case, async: true

  alias Engram.MCP.Sections

  # Built with String.duplicate so this file never holds a literal fence.
  @bt String.duplicate("`", 3)
  @note Enum.join(
          [
            "---",
            "title: T",
            "# yaml comment, not a heading",
            "---",
            "# Title",
            "",
            "## Todo",
            "",
            "a",
            "",
            @bt <> "sh",
            "# shell comment, not a heading",
            "## also not",
            @bt,
            "",
            "### Sub",
            "",
            "s",
            "",
            "## Done",
            "",
            "x",
            ""
          ],
          "\n"
        )

  test "headings skip frontmatter and fenced code" do
    assert Enum.map(Sections.headings(@note), &{&1.level, &1.text}) ==
             [{1, "Title"}, {2, "Todo"}, {3, "Sub"}, {2, "Done"}]
  end

  test "tilde fences and unclosed fences hide headings too" do
    assert Sections.headings("## A\n~~~\n## B\n~~~\n## C") |> Enum.map(& &1.text) == ["A", "C"]
    assert Sections.headings("## A\n" <> @bt <> "\n## B") |> Enum.map(& &1.text) == ["A"]
  end

  test "hashtags, 7 hashes and CRLF" do
    assert Sections.headings("#tag\n####### x\n## A\r\nbody\r\n") |> Enum.map(& &1.text) == ["A"]
  end

  test "find spans nested subsections and stops at the next same-or-higher heading" do
    assert {:ok, %{start: s, stop: e}} = Sections.find(@note, "Todo", 2)
    lines = String.split(@note, "\n")
    assert Enum.at(lines, s) == "## Todo"
    assert Enum.at(lines, e) == "## Done"
  end

  test "find respects level, and never matches inside a fence" do
    assert Sections.find(@note, "Todo", 3) == :error
    assert Sections.find(@note, "also not", 2) == :error
    assert Sections.find(@note, "yaml comment, not a heading", 1) == :error
  end

  test "section returns the heading and its body, fenced # lines included" do
    assert {:ok, text} = Sections.section(@note, "Todo")
    assert text =~ ~r/\A## Todo\n/
    assert text =~ "# shell comment, not a heading"
    assert text =~ "### Sub\n\ns"
    refute text =~ "## Done"
    assert Sections.section(@note, "Nope") == :error
  end

  test "insert start goes directly under the heading line" do
    assert {:ok, out} = Sections.insert(@note, "Todo", 2, "start", "NEW\n")
    assert out =~ "## Todo\nNEW\n\na"
  end

  # Review Focus 1 (nested subheadings) and 5 (fence inside the section)
  test "insert end goes after the last subsection line, before the next same-level heading" do
    assert {:ok, out} = Sections.insert(@note, "Todo", 2, "end", "NEW")
    assert out =~ "### Sub\n\ns\nNEW\n\n## Done"
  end

  # Review Focus 1 (last section)
  test "insert end on the last section keeps the trailing newline" do
    assert {:ok, out} = Sections.insert(@note, "Done", 2, "end", "y")
    assert String.ends_with?(out, "## Done\n\nx\ny\n")
  end

  test "insert on a missing heading is :error" do
    assert Sections.insert(@note, "Nope", 2, "end", "y") == :error
  end
end
```

Add one handler-level regression to `test/engram/mcp/handlers_edit_note_test.exs` (Review Focus 5 through the write path):

```elixir
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `mise exec -- mix test test/engram/mcp/sections_test.exs test/engram/mcp/handlers_edit_note_test.exs`
Expected: FAIL, `module Engram.MCP.Sections is not available`, and the fence regression fails (the old end-scan stops at `## fake`, leaving `## fake` and `old` in place).

- [ ] **Step 3: Implement**

```elixir
# lib/engram/mcp/sections.ex
defmodule Engram.MCP.Sections do
  @moduledoc """
  Markdown heading lookup shared by edit_note (replace_section,
  insert_section) and get_notes (section, outline). Pure: string in, data out.

  Lines inside the frontmatter block or a fenced code block are never
  headings, so a YAML `# comment` or a shell `# comment` in a fence can
  neither be matched nor end a section early.
  """

  alias Engram.Notes.Frontmatter

  @type heading :: %{line: non_neg_integer(), level: 1..6, text: String.t()}

  # `\#` because `#{` would interpolate. Trailing `\s*` also eats a CRLF `\r`.
  @heading_re ~r/^(\#{1,6})(?:\s+(.*?))?\s*$/
  @fence_re ~r/^\s{0,3}(`{3,}|~{3,})/

  @spec headings(String.t()) :: [heading()]
  def headings(content) do
    {found, _open} =
      content
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.drop(frontmatter_lines(content))
      |> Enum.reduce({[], nil}, &scan/2)

    Enum.reverse(found)
  end

  @spec find(String.t(), String.t(), 1..6 | nil) ::
          {:ok, %{start: non_neg_integer(), stop: non_neg_integer()}} | :error
  def find(content, heading, level) do
    hs = headings(content)
    want = String.trim(heading)

    case Enum.find(hs, &(&1.text == want and (is_nil(level) or &1.level == level))) do
      nil ->
        :error

      h ->
        line_count = content |> String.split("\n") |> length()

        stop =
          Enum.find_value(hs, line_count, fn x ->
            x.line > h.line and x.level <= h.level and x.line
          end)

        {:ok, %{start: h.line, stop: stop}}
    end
  end

  @spec section(String.t(), String.t()) :: {:ok, String.t()} | :error
  def section(content, heading) do
    with {:ok, %{start: s, stop: e}} <- find(content, heading, nil) do
      text =
        content
        |> String.split("\n")
        |> Enum.slice(s, e - s)
        |> Enum.join("\n")
        |> String.trim_trailing()

      {:ok, text}
    end
  end

  # "start": directly under the heading line. "end": after the section's last
  # non-blank line, so blank lines before the next heading stay where they are.
  @spec insert(String.t(), String.t(), 1..6, String.t(), String.t()) :: {:ok, String.t()} | :error
  def insert(content, heading, level, position, text) do
    with {:ok, %{start: s, stop: e}} <- find(content, heading, level) do
      lines = String.split(content, "\n")

      at =
        case position do
          "start" ->
            s + 1

          "end" ->
            # The heading line itself is non-blank, so this always finds one.
            back =
              lines
              |> Enum.slice(s, e - s)
              |> Enum.reverse()
              |> Enum.find_index(&(String.trim(&1) != ""))

            e - back
        end

      {:ok, lines |> List.insert_at(at, String.trim_trailing(text, "\n")) |> Enum.join("\n")}
    end
  end

  defp scan({line, i}, {acc, open}) do
    case {open, fence(line)} do
      {nil, nil} -> {heading(acc, line, i), nil}
      {nil, marker} -> {acc, marker}
      {open, nil} -> {acc, open}
      {open, marker} -> if closes?(open, marker), do: {acc, nil}, else: {acc, open}
    end
  end

  defp heading(acc, line, i) do
    case Regex.run(@heading_re, String.trim_leading(line)) do
      [_, hashes] -> [%{line: i, level: String.length(hashes), text: ""} | acc]
      [_, hashes, text] -> [%{line: i, level: String.length(hashes), text: text} | acc]
      nil -> acc
    end
  end

  defp fence(line) do
    case Regex.run(@fence_re, line) do
      [_, marker] -> marker
      nil -> nil
    end
  end

  # A fence closes on the same character, at least as long as the opener.
  defp closes?(open, marker),
    do:
      String.first(open) == String.first(marker) and
        String.length(marker) >= String.length(open)

  # Lines taken by the frontmatter block, so the scan starts after it.
  defp frontmatter_lines(content) do
    case Frontmatter.split(content) do
      {nil, _body} ->
        0

      {_block, body} ->
        prefix = String.replace_suffix(content, body, "")
        n = prefix |> String.split("\n") |> length()
        if String.ends_with?(prefix, "\n"), do: n - 1, else: n
    end
  end
end
```

In `handlers.ex`, add `alias Engram.MCP.Sections` and replace the body of the second `replace_section/7` clause (the one without the level guard) with:

```elixir
  defp replace_section(user, vault, path, heading, new_content, level, op) do
    with {:ok, note} <- Notes.get_note(user, vault, path),
         {:ok, current} <- Notes.authoritative_content(user, note) do
      case Sections.find(current, heading, level) do
        :error ->
          # The section was not updated, so this is not a success. Was `:ok`.
          {:error, "Heading not found: #{String.duplicate("#", level)} #{heading}"}

        {:ok, %{start: s, stop: e}} ->
          lines = String.split(current, "\n")

          final_content =
            (Enum.slice(lines, 0, s + 1) ++
               [String.trim_trailing(new_content, "\n")] ++ Enum.drop(lines, e))
            |> Enum.join("\n")

          Notes.upsert_note(user, vault, %{
            "path" => path,
            "content" => final_content,
            "mtime" => now(),
            "base_hash" => note.content_hash
          })
          |> upsert_reply(
            [
              ok: "Section '#{heading}' updated in #{path}",
              conflict: "Note changed concurrently; retry: #{path}",
              error: "Failed to update section in #{path}"
            ],
            %{"path" => path, "heading" => heading}
          )
      end
    else
      {:error, :not_found} -> {:error, "Note not found: #{path}"}
      {:error, reason} -> log_and_error(op, reason, "Could not read #{path}; retry")
    end
  end
```

Keep the comment block above the guard clause; replace its sentence about the end-scan comparing the raw level with: "The finder (`Engram.MCP.Sections.find/3`) is fence- and frontmatter-aware; the level guard still refuses 0 or 7+ before any lookup."

- [ ] **Step 4: Run to verify they pass**

Run: `mise exec -- mix test test/engram/mcp/sections_test.exs test/engram/mcp/handlers_edit_note_test.exs test/engram/mcp/handlers_test.exs test/engram/mcp/handlers_write_contract_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/mcp/sections.ex lib/engram/mcp/handlers.ex test/engram/mcp/sections_test.exs test/engram/mcp/handlers_edit_note_test.exs
git commit -m "fix(mcp): section edits skip code fences and frontmatter

Extracts Engram.MCP.Sections, the one heading finder for section edits and
reads. A # line inside a code fence or frontmatter is no longer a heading.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SUoP129aB16738p5qJLweA"
```

---

### Task 2: `edit_note` mode `insert_section`

**Files:**
- Modify: `lib/engram/mcp/handlers.ex` (`reject_other_mode/2`, new `run_edit/5` clause, new `insert_section/7`, new `resolve_insert_position/1`)
- Modify: `lib/engram/mcp/tools.ex` (`edit_note_def/0`)
- Modify: `test/engram/mcp/handlers_edit_note_test.exs` (the "an invalid mode" assertion, see below)
- Test: `test/engram/mcp/handlers_insert_section_test.exs` (new)
- Regenerate: `mcp-tools.json`

**Interfaces:**
- Consumes: `Sections.insert/5` (Task 1); `Handlers.rmw_upsert/5` (existing, rebuild may return `{:error, binary}` to refuse the write); `upsert_reply/3` (existing).
- Produces: `edit_note` input `mode: "insert_section"` with `heading` (required), `content` (required, non-blank), `level` (1..6, default 2), `position` (`"start" | "end"`, default `"end"`, `null` = default). Output `{path, mode: "insert_section", heading, replacements: null}`.

The old assertion `msg =~ "mode must be replace_text or replace_section"` in `handlers_edit_note_test.exs` ("an invalid mode is a fixable error") encodes the two-mode message this task intentionally widens. Replace it with `assert msg =~ "mode must be replace_text, replace_section or insert_section"` and say so in the commit body.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/mcp/handlers_insert_section_test.exs
defmodule Engram.MCP.HandlersInsertSectionTest do
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  @content "# N\n\n## Todo\n\na\n\n### Sub\n\ns\n\n## Done\n\nx\n"

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "N.md", "content" => @content, "mtime" => 1.0})
    %{user: user, vault: vault}
  end

  defp body(user, vault) do
    {:ok, note} = Notes.get_note(user, vault, "N.md")
    {:ok, content} = Notes.authoritative_content(user, note)
    content
  end

  defp insert(u, v, extra),
    do: Handlers.handle("edit_note", u, v, Map.merge(%{"path" => "N.md", "mode" => "insert_section"}, extra))

  test "position start puts the text directly under the heading", %{user: u, vault: v} do
    assert {:ok, _, %{"mode" => "insert_section", "heading" => "Todo", "replacements" => nil}} =
             insert(u, v, %{"heading" => "Todo", "content" => "- first", "position" => "start"})

    assert body(u, v) =~ "## Todo\n- first\n\na"
  end

  # Review Focus 1: nested subheadings
  test "position end lands after the subsections, before the next same-level heading", %{user: u, vault: v} do
    assert {:ok, _, _} = insert(u, v, %{"heading" => "Todo", "content" => "- last", "position" => "end"})
    assert body(u, v) =~ "### Sub\n\ns\n- last\n\n## Done"
  end

  # Review Focus 1: last section
  test "position end on the last section keeps the trailing newline", %{user: u, vault: v} do
    assert {:ok, _, _} = insert(u, v, %{"heading" => "Done", "content" => "y"})
    assert String.ends_with?(body(u, v), "## Done\n\nx\ny\n")
  end

  test "explicit null position means end", %{user: u, vault: v} do
    assert {:ok, _, _} = insert(u, v, %{"heading" => "Done", "content" => "y", "position" => nil})
    assert String.ends_with?(body(u, v), "x\ny\n")
  end

  test "a missing heading refuses and writes nothing", %{user: u, vault: v} do
    before = body(u, v)
    assert {:error, msg} = insert(u, v, %{"heading" => "Nope", "content" => "y"})
    assert msg =~ "Heading not found: ## Nope"
    assert body(u, v) == before
  end

  test "level picks the heading level, and is validated", %{user: u, vault: v} do
    assert {:ok, _, _} = insert(u, v, %{"heading" => "Sub", "level" => 3, "content" => "z"})
    assert body(u, v) =~ "### Sub\n\ns\nz\n"
    assert {:error, "level must be between 1 and 6"} = insert(u, v, %{"heading" => "Sub", "level" => 7, "content" => "z"})
  end

  test "bad position, blank content, missing heading and missing note are fixable", %{user: u, vault: v} do
    assert {:error, "position must be start or end"} =
             insert(u, v, %{"heading" => "Todo", "content" => "y", "position" => "middle"})

    assert {:error, "content is required for mode insert_section"} =
             insert(u, v, %{"heading" => "Todo", "content" => "  "})

    assert {:error, "heading is required for mode insert_section"} = insert(u, v, %{"content" => "y"})

    assert {:error, "Note not found: Gone.md"} =
             Handlers.handle("edit_note", u, v, %{"path" => "Gone.md", "mode" => "insert_section", "heading" => "A", "content" => "y"})
  end

  test "text params are refused under insert_section; position is refused elsewhere", %{user: u, vault: v} do
    assert {:error, "find is only valid with mode replace_text"} =
             insert(u, v, %{"heading" => "Todo", "content" => "y", "find" => "a"})

    assert {:error, "position is only valid with mode insert_section"} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md", "mode" => "replace_section", "heading" => "Todo", "content" => "z", "position" => "end"
             })

    # strict-mode nulls are not strays
    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md", "mode" => "replace_text", "find" => "x", "replace" => "w", "position" => nil
             })
  end

  test "schema declares the mode and position" do
    {:ok, tool} = Engram.MCP.Tools.get("edit_note")
    props = tool.inputSchema["properties"]
    assert "insert_section" in props["mode"]["enum"]
    assert props["position"]["enum"] == ["start", "end"]
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/engram/mcp/handlers_insert_section_test.exs`
Expected: FAIL, `mode must be replace_text or replace_section, got "insert_section"`.

- [ ] **Step 3: Implement**

`handlers.ex`, replace the three `reject_other_mode/2` clauses:

```elixir
  defp reject_other_mode(args, "replace_text") do
    with :ok <- reject_params(args, @section_params, "replace_section or insert_section"),
         do: reject_params(args, ["position"], "insert_section")
  end

  defp reject_other_mode(args, "replace_section") do
    with :ok <- reject_params(args, @text_params, "replace_text"),
         do: reject_params(args, ["position"], "insert_section")
  end

  defp reject_other_mode(args, "insert_section"),
    do: reject_params(args, @text_params, "replace_text")

  defp reject_other_mode(_args, mode),
    do:
      {:error,
       "mode must be replace_text, replace_section or insert_section, got #{inspect(mode)}"}
```

Add after the `run_edit(..., "replace_section", ...)` clause:

```elixir
  defp run_edit(user, vault, path, "insert_section", args) do
    level = args["level"] || 2

    cond do
      not is_binary(args["heading"]) ->
        {:error, "heading is required for mode insert_section"}

      not is_binary(args["content"]) or String.trim(args["content"]) == "" ->
        {:error, "content is required for mode insert_section"}

      level < 1 or level > 6 ->
        {:error, "level must be between 1 and 6"}

      true ->
        with {:ok, position} <- resolve_insert_position(args["position"]) do
          user
          |> insert_section(vault, path, args["heading"], level, position, args["content"])
          |> tag_mode("insert_section", %{"replacements" => nil})
        end
    end
  end

  defp resolve_insert_position(nil), do: {:ok, "end"}
  defp resolve_insert_position(p) when p in ["start", "end"], do: {:ok, p}
  defp resolve_insert_position(_), do: {:error, "position must be start or end"}

  # Through rmw_upsert: the rebuild runs against the authority (#1159) on every
  # attempt, and a missing heading refuses inside it, so nothing is written.
  defp insert_section(user, vault, path, heading, level, position, text) do
    rebuild = fn current ->
      case Sections.insert(current, heading, level, position, text) do
        {:ok, updated} -> updated
        :error -> {:error, "Heading not found: #{String.duplicate("#", level)} #{heading}"}
      end
    end

    case rmw_upsert(user, vault, path, rebuild) do
      {:error, :not_found} ->
        {:error, "Note not found: #{path}"}

      result ->
        upsert_reply(
          result,
          [
            ok: "Inserted at the #{position} of section '#{heading}' in #{path}",
            conflict: "Note changed concurrently; retry: #{path}",
            error: "Failed to update section in #{path}"
          ],
          %{"path" => path, "heading" => heading}
        )
    end
  end
```

`tools.ex`, `edit_note_def/0`:
- description:
  ```elixir
  "Change part of an existing note. mode replace_text finds exact text and replaces " <>
    "it (first occurrence by default); mode replace_section replaces everything under " <>
    "one heading; mode insert_section adds content under a heading, at the start or " <>
    "end of that section, keeping what is there. Fails without writing if the text or " <>
    "heading is not found, or if expected_replacements does not match. To add text at " <>
    "the top or bottom of the note use append_to_note. To rewrite the whole note use write_note."
  ```
- `mode`: `"enum" => ["replace_text", "replace_section", "insert_section"]`, description `"replace_text, replace_section or insert_section"`.
- `heading`: description `"replace_section and insert_section: heading text without the # prefix"`.
- `content`: description `"replace_section: new content for under the heading; insert_section: content to add"`.
- `level`: description `"replace_section and insert_section: heading level 1-6 (default 2)"`.
- new `position`:
  ```elixir
  "position" => %{
    "type" => "string",
    "enum" => ["start", "end"],
    "default" => "end",
    "description" =>
      "insert_section only: start (directly under the heading) or end (default; after " <>
        "the section's last line, including its subsections)"
  }
  ```

Update the "an invalid mode" assertion as described above.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/engram/mcp/handlers_insert_section_test.exs test/engram/mcp/handlers_edit_note_test.exs test/engram/mcp/tools_descriptions_test.exs test/engram/mcp/tools_annotations_test.exs test/engram/mcp/tools_aliases_test.exs`
Expected: PASS.

- [ ] **Step 5: Regenerate snapshot and commit**

```bash
mise exec -- mix engram.mcp.tools_json
git add lib/engram/mcp/handlers.ex lib/engram/mcp/tools.ex mcp-tools.json test/engram/mcp/handlers_insert_section_test.exs test/engram/mcp/handlers_edit_note_test.exs
git commit -m "feat(mcp): edit_note mode insert_section

Adds content at the start or end of a heading's section without replacing
it. Refuses and writes nothing when the heading is missing.

The invalid-mode assertion now expects the three-mode message; the old
two-mode text is the behavior this change widens.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SUoP129aB16738p5qJLweA"
```

---

### Task 3: `get_notes(section | outline)`

**Files:**
- Modify: `lib/engram/mcp/handlers.ex` (`handle("get_notes", ...)` at ~:239; new `narrow_to_section/2`, `heading_missing_msg/3`, `render_notes/3`, `outline_entry/1`)
- Modify: `lib/engram/mcp/tools.ex` (`get_notes_def/0`)
- Test: `test/engram/mcp/handlers_partial_read_test.exs` (new)
- Regenerate: `mcp-tools.json`

**Interfaces:**
- Consumes: `Sections.section/2`, `Sections.headings/1` (Task 1).
- Produces:
  - `section: String.t()`: exactly one path; the found note's `content` becomes that section (heading line included, any heading level, first match). Missing heading: fixable `isError` listing the note's headings. Missing note: the usual `found: false` entry.
  - `outline: true`: per found note, `outline: [%{"level" => 1..6, "heading" => String.t()}]` and NO `content` key; text shows an indented bullet list. Works with up to 20 paths.
  - `section` + `outline` together: fixable error. `null` on either = absent.
  - `render_notes(user, fetched, outline?) :: {:ok, String.t(), map()}` where `fetched :: [{path, Note.t() | nil}]` (Task 4 adds a `links?` argument).

Decision: a missing section is an error, not `found: false`, because `found` means "the note exists". Restricting `section` to one path keeps that error unambiguous.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/mcp/handlers_partial_read_test.exs
defmodule Engram.MCP.HandlersPartialReadTest do
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  @bt String.duplicate("`", 3)

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    content =
      "---\ntags: [a]\n# not a heading\n---\n# T\n\n## Todo\n\na\n\n#{@bt}\n## fake\n#{@bt}\n\n### Sub\n\ns\n\n## Done\n\nx\n"

    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "P.md", "content" => content, "mtime" => 1.0})
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Q.md", "content" => "plain text", "mtime" => 1.0})
    %{user: user, vault: vault}
  end

  defp get(u, v, args), do: Handlers.handle("get_notes", u, v, args)

  # Review Focus 5
  test "section returns only that section, through fences, stopping at the next same-level heading",
       %{user: u, vault: v} do
    assert {:ok, text, %{"notes" => [n]}} = get(u, v, %{"paths" => ["P.md"], "section" => "Todo"})
    assert n["found"] == true
    assert n["content"] =~ ~r/\A## Todo\n/
    assert n["content"] =~ "## fake"
    assert n["content"] =~ "### Sub\n\ns"
    refute n["content"] =~ "## Done"
    refute n["content"] =~ "tags:"
    assert text =~ "## Todo"
  end

  test "a missing section is a fixable error that lists the headings", %{user: u, vault: v} do
    assert {:error, msg} = get(u, v, %{"paths" => ["P.md"], "section" => "Nope"})
    assert msg == "Heading not found in P.md: Nope. Headings: T, Todo, Sub, Done"

    assert {:error, "Heading not found in Q.md: Nope. This note has no headings."} =
             get(u, v, %{"paths" => ["Q.md"], "section" => "Nope"})
  end

  test "section on a missing note keeps found:false", %{user: u, vault: v} do
    assert {:ok, _, %{"notes" => [%{"path" => "Gone.md", "found" => false}]}} =
             get(u, v, %{"paths" => ["Gone.md"], "section" => "Todo"})
  end

  test "section takes one path, must be non-blank, and excludes outline", %{user: u, vault: v} do
    assert {:error, "section reads one note at a time; pass a single path"} =
             get(u, v, %{"paths" => ["P.md", "Q.md"], "section" => "Todo"})

    assert {:error, "section must name a heading, e.g. \"Todo\""} =
             get(u, v, %{"paths" => ["P.md"], "section" => " "})

    assert {:error, "Pass section or outline, not both"} =
             get(u, v, %{"paths" => ["P.md"], "section" => "Todo", "outline" => true})
  end

  # Review Focus 5
  test "outline lists real headings only, drops content, and works on many paths", %{user: u, vault: v} do
    assert {:ok, text, %{"notes" => [p, q, missing]}} =
             get(u, v, %{"paths" => ["P.md", "Q.md", "Gone.md"], "outline" => true})

    assert p["outline"] == [
             %{"level" => 1, "heading" => "T"},
             %{"level" => 2, "heading" => "Todo"},
             %{"level" => 3, "heading" => "Sub"},
             %{"level" => 2, "heading" => "Done"}
           ]

    refute Map.has_key?(p, "content")
    assert q["outline"] == []
    assert missing == %{"path" => "Gone.md", "found" => false}
    assert text =~ "- T\n  - Todo\n    - Sub\n  - Done"
    assert text =~ "(no headings)"
  end

  test "explicit nulls behave as absent", %{user: u, vault: v} do
    assert {:ok, _, %{"notes" => [n]}} =
             get(u, v, %{"paths" => ["P.md"], "section" => nil, "outline" => nil})

    assert n["content"] =~ "## Done"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/engram/mcp/handlers_partial_read_test.exs`
Expected: FAIL (section is ignored; full content returned).

- [ ] **Step 3: Implement**

Replace `handle("get_notes", ...)`:

```elixir
  def handle("get_notes", user, vault, args) do
    paths = args["paths"] || []
    section = args["section"]
    outline? = args["outline"] == true

    # `paths` being a list of strings is already enforced by the dispatch-level
    # schema validator (mcp_controller.ex). The checks left are the ones the
    # schema does NOT declare.
    cond do
      paths == [] ->
        {:error, "paths must be a non-empty array"}

      length(paths) > 20 ->
        {:error, "Too many paths (max 20). Split into multiple calls."}

      is_binary(section) and outline? ->
        {:error, "Pass section or outline, not both"}

      is_binary(section) and String.trim(section) == "" ->
        {:error, "section must name a heading, e.g. \"Todo\""}

      is_binary(section) and length(paths) > 1 ->
        {:error, "section reads one note at a time; pass a single path"}

      true ->
        fetched =
          Enum.map(paths, fn path ->
            case Notes.get_note(user, vault, path) do
              {:ok, note} -> {path, note}
              {:error, :not_found} -> {path, nil}
            end
          end)

        with {:ok, fetched} <- narrow_to_section(fetched, section) do
          render_notes(user, fetched, outline?)
        end
    end
  end
```

Add private helpers (next to `note_payload/1`):

```elixir
  defp narrow_to_section(fetched, nil), do: {:ok, fetched}
  defp narrow_to_section([{_path, nil}] = fetched, _section), do: {:ok, fetched}

  defp narrow_to_section([{path, note}], section) do
    content = note.content || ""

    case Sections.section(content, section) do
      {:ok, text} -> {:ok, [{path, %{note | content: text}}]}
      :error -> {:error, heading_missing_msg(path, section, content)}
    end
  end

  defp heading_missing_msg(path, section, content) do
    case Sections.headings(content) do
      [] -> "Heading not found in #{path}: #{section}. This note has no headings."
      hs -> "Heading not found in #{path}: #{section}. Headings: #{Enum.map_join(hs, ", ", & &1.text)}"
    end
  end

  defp render_notes(_user, fetched, outline?) do
    {texts, notes} =
      fetched
      |> Enum.map(fn
        {path, nil} ->
          {"Note not found: #{path}", %{"path" => path, "found" => false}}

        {_path, note} ->
          {text, payload} =
            if outline?, do: outline_entry(note), else: {format_get_note(note), note_payload(note)}

          {text, Map.put(payload, "found", true)}
      end)
      |> Enum.unzip()

    {:ok, Enum.join(texts, "\n\n---\n\n"), %{"notes" => notes}}
  end

  defp outline_entry(note) do
    outline =
      Enum.map(Sections.headings(note.content || ""), &%{"level" => &1.level, "heading" => &1.text})

    lines =
      if outline == [],
        do: ["(no headings)"],
        else: Enum.map(outline, &(String.duplicate("  ", &1["level"] - 1) <> "- " <> &1["heading"]))

    payload = note |> note_payload() |> Map.delete("content") |> Map.put("outline", outline)
    {Enum.join(["**Path:** #{note.path}" | lines], "\n"), payload}
  end
```

`tools.ex`, `get_notes_def/0`:
- description:
  ```elixir
  "Retrieve the full content of multiple notes in one call (1-20 paths). " <>
    "Also reads a single note: pass one path. " <>
    "Use to inventory a folder (list_folder then get_notes) or to read a batch " <>
    "of search results without N round-trips. Missing paths are reported inline. " <>
    "To save tokens on long notes, pass outline: true for the heading list only, or " <>
    "section with one path to read just that heading's section."
  ```
- new input properties:
  ```elixir
  "section" => %{
    "type" => "string",
    "description" =>
      "Heading text without the # prefix, e.g. \"Todo\". Returns only that section " <>
        "(heading line included, subsections included). One path only."
  },
  "outline" => %{
    "type" => "boolean",
    "default" => false,
    "description" => "true returns each note's headings (level and text) instead of its content"
  }
  ```
- outputSchema item properties, add:
  ```elixir
  "outline" => %{
    "type" => "array",
    "description" => "Only with outline: true; replaces content",
    "items" => %{
      "type" => "object",
      "properties" => %{"level" => %{"type" => "integer"}, "heading" => %{"type" => "string"}},
      "required" => ["level", "heading"]
    }
  }
  ```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/engram/mcp/handlers_partial_read_test.exs test/engram/mcp/handlers_test.exs test/engram/mcp/handlers_get_note_test.exs test/engram/mcp/tools_descriptions_test.exs test/engram_web/controllers/mcp_listings_structured_output_test.exs`
Expected: PASS.

- [ ] **Step 5: Regenerate snapshot and commit**

```bash
mise exec -- mix engram.mcp.tools_json
git add lib/engram/mcp/handlers.ex lib/engram/mcp/tools.ex mcp-tools.json test/engram/mcp/handlers_partial_read_test.exs
git commit -m "feat(mcp): get_notes reads one section or the outline

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SUoP129aB16738p5qJLweA"
```

---

### Task 4: `get_notes(include_links: true)`

**Files:**
- Modify: `lib/engram/mcp/handlers.ex` (`handle("get_notes", ...)` passes `links?`; `render_notes/4`; new `links_payload/2`, `format_links/1`, `list_or_none/1`)
- Modify: `lib/engram/mcp/tools.ex` (`get_notes_def/0`)
- Test: `test/engram/mcp/handlers_links_test.exs` (new)
- Regenerate: `mcp-tools.json`

**Interfaces:**
- Consumes: `Engram.Links.backlinks_for_note(user, note_id) :: [%{source_path, source_title, ...}]` (`lib/engram/links.ex:898`, capped at `Links.backlinks_limit/0`, user-scoped, one entry per edge); `Engram.Links.links_for_note(user, note_id) :: [%{target_text, target_path, target_note_id, target_attachment_id, dangling, ...}]` (`lib/engram/links.ex:809`). Vault scoping comes from resolution: `Links.resolve_target/4` and `bind_danglers_for_hmac/3` only bind within the source's vault, so an edge never points across vaults. The cross-vault test below pins that.
- Produces: per found note, when `include_links == true`: `backlinks :: [path]` (notes linking here, unique), `outgoing :: [path]` (resolved note targets, unique), `unresolved :: [target_text]` (dangling targets, unique). Composes with `section` and `outline`. Not-found entries carry no link keys.

Decisions: lists of paths, not objects (smallest useful payload; `get_notes` on a path gives the title). Links to attachments (embeds) are neither `outgoing` nor `unresolved`: `outgoing` is the note graph.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/mcp/handlers_links_test.exs
defmodule Engram.MCP.HandlersLinksTest do
  use Engram.DataCase, async: true

  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    %{user: user, a: insert(:vault, user: user), b: insert(:vault, user: user)}
  end

  # Upsert every note first, then extract links, so resolution does not depend
  # on creation order or on the async indexing job.
  defp seed(user, vault, notes) do
    saved =
      for {path, content} <- notes do
        {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0})
        {note, content}
      end

    for {note, content} <- saved, do: :ok = Links.replace_links(user, vault, note.id, Parser.extract(content))
    :ok
  end

  defp get(u, v, args), do: Handlers.handle("get_notes", u, v, Map.put(args, "include_links", true))

  test "found notes carry backlinks, outgoing and unresolved; a miss carries none", %{user: u, a: a} do
    seed(u, a, [
      {"Target.md", "# T\n\nsee [[Source]] and [[Ghost]] and [[Ghost]]"},
      {"Source.md", "see [[Target]] twice [[Target]]"}
    ])

    assert {:ok, text, %{"notes" => [t, missing]}} = get(u, a, %{"paths" => ["Target.md", "Nope.md"]})
    assert t["backlinks"] == ["Source.md"]
    assert t["outgoing"] == ["Source.md"]
    assert t["unresolved"] == ["Ghost"]
    assert missing == %{"path" => "Nope.md", "found" => false}
    assert text =~ "Backlinks: Source.md"
    assert text =~ "Unresolved: Ghost"
  end

  # Review Focus 4
  test "links never cross vaults", %{user: u, a: a, b: b} do
    seed(u, a, [{"Target.md", "# T"}])
    seed(u, b, [{"Source.md", "see [[Target]]"}])

    assert {:ok, _, %{"notes" => [t]}} = get(u, a, %{"paths" => ["Target.md"]})
    assert t["backlinks"] == []

    assert {:ok, _, %{"notes" => [s]}} = get(u, b, %{"paths" => ["Source.md"]})
    assert s["outgoing"] == []
    assert s["unresolved"] == ["Target"]
  end

  test "composes with outline and section", %{user: u, a: a} do
    seed(u, a, [{"Target.md", "# T\n\n## Part\n\nx"}, {"Source.md", "[[Target]]"}])

    assert {:ok, _, %{"notes" => [o]}} = get(u, a, %{"paths" => ["Target.md"], "outline" => true})
    assert o["backlinks"] == ["Source.md"]
    refute Map.has_key?(o, "content")

    assert {:ok, _, %{"notes" => [s]}} = get(u, a, %{"paths" => ["Target.md"], "section" => "Part"})
    assert s["backlinks"] == ["Source.md"]
    assert s["content"] =~ "## Part"
  end

  test "without the flag, or with null, the payload has no link keys", %{user: u, a: a} do
    seed(u, a, [{"A.md", "a"}])

    for args <- [%{"paths" => ["A.md"]}, %{"paths" => ["A.md"], "include_links" => nil}] do
      {:ok, _, %{"notes" => [n]}} = Handlers.handle("get_notes", u, a, args)
      refute Map.has_key?(n, "backlinks")
      refute Map.has_key?(n, "outgoing")
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/engram/mcp/handlers_links_test.exs`
Expected: FAIL, `t["backlinks"]` is nil.

- [ ] **Step 3: Implement**

In `handle("get_notes", ...)` change the last call to `render_notes(user, fetched, outline?, args["include_links"] == true)` and replace `render_notes/3` with:

```elixir
  defp render_notes(user, fetched, outline?, links?) do
    {texts, notes} =
      fetched
      |> Enum.map(fn
        {path, nil} ->
          {"Note not found: #{path}", %{"path" => path, "found" => false}}

        {_path, note} ->
          {text, payload} =
            if outline?, do: outline_entry(note), else: {format_get_note(note), note_payload(note)}

          payload = Map.put(payload, "found", true)

          if links? do
            links = links_payload(user, note)
            {text <> "\n\n" <> format_links(links), Map.merge(payload, links)}
          else
            {text, payload}
          end
      end)
      |> Enum.unzip()

    {:ok, Enum.join(texts, "\n\n---\n\n"), %{"notes" => notes}}
  end

  # Both reads are user-scoped by the Links context; vault scoping holds because
  # an edge only ever resolves inside its source note's vault.
  defp links_payload(user, note) do
    outgoing = Engram.Links.links_for_note(user, note.id)

    %{
      "backlinks" =>
        user
        |> Engram.Links.backlinks_for_note(note.id)
        |> Enum.map(& &1.source_path)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq(),
      "outgoing" =>
        outgoing |> Enum.map(& &1.target_path) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      "unresolved" =>
        outgoing |> Enum.filter(& &1.dangling) |> Enum.map(& &1.target_text) |> Enum.uniq()
    }
  end

  defp format_links(links) do
    Enum.join(
      [
        "Backlinks: " <> list_or_none(links["backlinks"]),
        "Links to: " <> list_or_none(links["outgoing"]),
        "Unresolved: " <> list_or_none(links["unresolved"])
      ],
      "\n"
    )
  end

  defp list_or_none([]), do: "none"
  defp list_or_none(items), do: Enum.join(items, ", ")
```

If the cross-vault test goes red, the leak is in `Engram.Links`, not here: fix it there by adding `l.vault_id == ^vault_id` to the edge query, never by filtering in the handler.

`tools.ex`, `get_notes_def/0`:
- description: append `" Pass include_links: true to also get, per note, the notes linking to it, the notes it links to, and its links that point at no existing note."`
- input property:
  ```elixir
  "include_links" => %{
    "type" => "boolean",
    "default" => false,
    "description" => "true adds backlinks, outgoing and unresolved link lists to each found note"
  }
  ```
- outputSchema item properties:
  ```elixir
  "backlinks" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Paths of notes linking to this one (include_links)"},
  "outgoing" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Paths of notes this one links to (include_links)"},
  "unresolved" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Link targets that match no note (include_links)"}
  ```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/engram/mcp/handlers_links_test.exs test/engram/mcp/handlers_partial_read_test.exs test/engram/mcp/handlers_test.exs`
Expected: PASS.

- [ ] **Step 5: Regenerate snapshot and commit**

```bash
mise exec -- mix engram.mcp.tools_json
git add lib/engram/mcp/handlers.ex lib/engram/mcp/tools.ex mcp-tools.json test/engram/mcp/handlers_links_test.exs
git commit -m "feat(mcp): get_notes can include backlinks and outgoing links

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SUoP129aB16738p5qJLweA"
```

---

### Task 5: `search_notes` with no or blank query lists recently updated notes

**Files:**
- Modify: `lib/engram/notes.ex` (add `list_recent_notes/3` after `list_notes_in_folder/3`, ~:5286)
- Modify: `lib/engram/mcp/handlers.ex` (both `search_notes` clauses at ~:85-102; new `search_kind/1`, `render_recent/2`)
- Modify: `lib/engram/mcp/tools.ex` (`search_notes_def/0`: drop `required`, update `query` and tool description)
- Test: `test/engram/notes_recent_test.exs`, `test/engram/mcp/handlers_recent_test.exs` (new)
- Regenerate: `mcp-tools.json`

**Interfaces:**
- Produces:
  - `Engram.Notes.list_recent_notes(user, vault, limit :: pos_integer()) :: {:ok, [Note.t()]}`: live `kind == "note"` rows, newest `updated_at` first, metadata only, decrypted.
  - `Handlers.search_kind(args) :: {:ok, :query | :recent | :similar} | {:error, String.t()}` (private; Task 6 fills the `:similar` branch). `:recent` when `query` is absent, `null`, `""` or whitespace and `similar_to` is absent/`null`.
  - Recent results use the existing `search_notes` output shape: `score: 0`, `text: ""`, `title`, `source_path`, `tags`, plus `vault_id`/`vault` only in cross-vault mode.

Decisions, deliberate:
- The listing never calls `Search.search/4`, so it never embeds and never spends `ai_searches_per_day`.
- Not filtered by the Free index cap (same as `list_folder`): hiding a Free user's newest notes from "what changed" would hide exactly what they just wrote.
- Filters (`tags`, `folder`, `type`, the four date bounds) with a blank query are a fixable error, not silently ignored: the listing is not filtered, and returning unfiltered notes to a filtered ask is the silent-wrong-answer class. `mode` and `diversity` are ranking knobs and are ignored (clients that always send defaults must not break).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/notes_recent_test.exs
defmodule Engram.NotesRecentTest do
  use Engram.DataCase, async: true
  alias Engram.Notes

  test "newest updated first, limited, notes only, own vault only" do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    other = insert(:vault, user: user)

    for {p, t} <- [{"old.md", 1.0}, {"mid.md", 2.0}, {"new.md", 3.0}] do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => p, "content" => "x", "mtime" => t})
      Process.sleep(2)
    end

    {:ok, _} = Notes.upsert_note(user, other, %{"path" => "elsewhere.md", "content" => "x", "mtime" => 9.0})

    assert {:ok, notes} = Notes.list_recent_notes(user, vault, 2)
    assert Enum.map(notes, & &1.path) == ["new.md", "mid.md"]
  end
end
```

```elixir
# test/engram/mcp/handlers_recent_test.exs
defmodule Engram.MCP.HandlersRecentTest do
  use Engram.DataCase, async: true

  import Mox

  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup :verify_on_exit!

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "# R\n\nx", "mtime" => 1.0})
    # Review Focus 3: the embedder must never be called on this path.
    expect(Engram.MockEmbedder, :embed_texts, 0, fn _texts, _opts -> flunk("must not embed") end)
    %{user: user, vault: vault}
  end

  for q <- [:absent, nil, "", "   "] do
    test "query #{inspect(q)} lists recent notes without searching", %{user: u, vault: v} do
      args = if unquote(q) == :absent, do: %{}, else: %{"query" => unquote(q)}

      assert {:ok, text, %{"results" => [hit]}} = Handlers.handle("search_notes", u, v, args)
      assert hit["source_path"] == "r.md"
      assert hit["score"] == 0
      refute Map.has_key?(hit, "vault")
      assert text =~ "Recently updated"
    end
  end

  # Review Focus 3: no budget spend. Cap 0 refuses every Search.search/4 call
  # (control), and the recent listing still answers.
  test "a zero search budget does not block the listing", %{user: u, vault: v} do
    insert(:user_limit_override, user: u, key: "ai_searches_per_day", value: %{"v" => 0})
    assert {:error, :search_cap_exceeded, 0} = Engram.Search.search(u, v, "anything")
    assert {:ok, _, %{"results" => [_]}} = Handlers.handle("search_notes", u, v, %{"query" => " "})
  end

  test "cross-vault listing merges newest first and labels vaults", %{user: u, vault: v} do
    other = insert(:vault, user: u, name: "Other")
    Process.sleep(2)
    {:ok, _} = Notes.upsert_note(u, other, %{"path" => "o.md", "content" => "o", "mtime" => 2.0})

    assert {:ok, _, %{"results" => [first, second]}} =
             Handlers.handle("search_notes", u, {:cross_vault, [v, other]}, %{"limit" => 5})

    assert {first["source_path"], first["vault"]} == {"o.md", "Other"}
    assert second["source_path"] == "r.md"
    assert second["vault_id"] == to_string(v.id)
  end

  test "a filter without a query is a fixable error; a null filter is not", %{user: u, vault: v} do
    assert {:error, "tags needs a query or similar_to; omit it to list recently updated notes"} =
             Handlers.handle("search_notes", u, v, %{"tags" => ["x"]})

    assert {:ok, _, _} =
             Handlers.handle("search_notes", u, v, %{"tags" => nil, "mode" => "hybrid", "diversity" => 0.3})
  end

  test "an empty vault answers 'No notes yet.'", %{user: u} do
    empty = insert(:vault, user: u)
    assert {:ok, "No notes yet.", %{"results" => []}} = Handlers.handle("search_notes", u, empty, %{})
  end

  test "query is no longer required in the schema" do
    {:ok, tool} = Engram.MCP.Tools.get("search_notes")
    refute "query" in (tool.inputSchema["required"] || [])
  end
end
```

If the `vault` factory does not accept `name:`, create the vault then set its name the way `test/engram/mcp/handlers_test.exs` does for cross-vault labels (grep `cross_vault` there) and use that.

- [ ] **Step 2: Run to verify both fail**

Run: `mise exec -- mix test test/engram/notes_recent_test.exs test/engram/mcp/handlers_recent_test.exs`
Expected: FAIL, `Notes.list_recent_notes/3 is undefined`, and the embedder expectation of 0 is violated (the current handler embeds `""`).

- [ ] **Step 3: Implement**

`lib/engram/notes.ex`, after `list_notes_in_folder/3`:

```elixir
  @doc """
  Most recently updated live notes in `vault`, newest first, metadata only.
  Backs `search_notes` with no query ("what changed recently").
  """
  @spec list_recent_notes(map(), map(), pos_integer()) :: {:ok, [Note.t()]}
  def list_recent_notes(user, vault, limit) when is_integer(limit) and limit > 0 do
    {:ok, notes} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in scoped_live(user, vault),
            where: n.kind == "note",
            order_by: [desc: n.updated_at, desc: n.id],
            limit: ^limit,
            select: struct(n, @note_meta_fields)
          )
        )
      end)

    {:ok, decrypt_or_raise!(notes, user)}
  end
```

`lib/engram/mcp/handlers.ex`, replace both `search_notes` clauses (keep the long comment above the cross-vault clause):

```elixir
  def handle("search_notes", user, {:cross_vault, vaults}, args) do
    names = Map.new(vaults, &{to_string(&1.id), &1.name})

    case search_kind(args) do
      {:ok, :recent} ->
        limit = min(args["limit"] || 5, 20)

        vaults
        |> Enum.flat_map(fn v ->
          {:ok, notes} = Notes.list_recent_notes(user, v, limit)
          Enum.map(notes, &{&1, v})
        end)
        |> Enum.sort_by(fn {n, _v} -> n.updated_at end, {:desc, DateTime})
        |> Enum.take(limit)
        |> render_recent(names)

      {:ok, :query} ->
        opts =
          Keyword.merge(build_search_opts(args),
            cross_vault: true,
            allow_cross_vault: true,
            vault_ids: Enum.map(vaults, &to_string(&1.id))
          )

        render_search(Search.search(user, nil, args["query"], opts), names)

      {:error, _} = err ->
        err
    end
  end

  def handle("search_notes", user, vault, args) do
    case search_kind(args) do
      {:ok, :recent} ->
        {:ok, notes} = Notes.list_recent_notes(user, vault, min(args["limit"] || 5, 20))
        render_recent(Enum.map(notes, &{&1, vault}), %{})

      {:ok, :query} ->
        render_search(Search.search(user, vault, args["query"], build_search_opts(args)), %{})

      {:error, _} = err ->
        err
    end
  end
```

Private helpers (near `render_search/2`):

```elixir
  @search_filters ~w(tags folder type created_after created_before updated_after updated_before)

  defp search_kind(args) do
    if String.trim(args["query"] || "") == "" do
      case Enum.find(@search_filters, &(not is_nil(args[&1]))) do
        nil -> {:ok, :recent}
        p -> {:error, "#{p} needs a query or similar_to; omit it to list recently updated notes"}
      end
    else
      {:ok, :query}
    end
  end

  # Same result shape as render_search/2; vault labels only in cross-vault mode.
  defp render_recent(pairs, names) do
    text =
      if pairs == [] do
        "No notes yet."
      else
        Enum.join(
          ["Recently updated:" | Enum.map(pairs, fn {n, _v} -> "- #{n.path} (#{n.updated_at})" end)],
          "\n"
        )
      end

    results =
      Enum.map(pairs, fn {n, v} ->
        payload = %{
          "score" => 0,
          "title" => n.title,
          "source_path" => n.path,
          "tags" => n.tags || [],
          "text" => ""
        }

        if names == %{},
          do: payload,
          else: Map.merge(payload, %{"vault_id" => to_string(v.id), "vault" => names[to_string(v.id)]})
      end)

    {:ok, text, %{"results" => results}}
  end
```

`tools.ex`, `search_notes_def/0`:
- description:
  ```elixir
  "Search your personal knowledge base. Finds relevant notes using semantic " <>
    "search. Searches across ALL your vaults by default; pass vault_id to limit " <>
    "to one. Omit query to list the most recently updated notes instead. Use when " <>
    "the user asks about their notes, vault, knowledge, or memory."
  ```
- `query` description: `"Natural language search query. Omit, or leave empty, to list the most recently updated notes (filters then do not apply)."`
- delete `"required" => ["query"]` from `inputSchema`.

- [ ] **Step 4: Run to verify they pass**

Run: `mise exec -- mix test test/engram/notes_recent_test.exs test/engram/mcp/handlers_recent_test.exs test/engram/mcp/handlers_search_mode_test.exs test/engram_web/controllers/mcp_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Regenerate snapshot and commit**

```bash
mise exec -- mix engram.mcp.tools_json
git add lib/engram/notes.ex lib/engram/mcp/handlers.ex lib/engram/mcp/tools.ex mcp-tools.json test/engram/notes_recent_test.exs test/engram/mcp/handlers_recent_test.exs
git commit -m "feat(mcp): search_notes with no query lists recent notes

Never embeds and never spends the search budget.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SUoP129aB16738p5qJLweA"
```

---

### Task 6: `search_notes(similar_to: path)` from stored vectors

**How vectors are keyed (read before implementing):**
- One Qdrant point per chunk. `Engram.Indexing.build_entry/3` (`lib/engram/indexing.ex:~1020`) mints `point_id = Ecto.UUID.generate()` per chunk and writes named vectors `%{"dense" => v, "keyword" => sparse}`, or only `%{"keyword" => sparse}` on a sparse-only pass (embed budget spent). The id is recorded on the chunk row: `chunks.qdrant_point_id` (`lib/engram/notes/chunk.ex`), one row per `{note_id, position}`.
- `notes.dense_indexed_hash` is non-nil only when the last pass wrote dense vectors (`EmbedNote.stamp_embed_hash/3`, `lib/engram/workers/embed_note.ex:487`); a sparse-only pass or a no-chunks pass (empty, or past the index cap) nils it. A note that was never embedded has it nil too.
- Qdrant's Query API (`POST /collections/{c}/points/query`, already used by `Qdrant.do_search/2`) accepts `query: {recommend: {positive: [ids], strategy: "average_vector"}}` with `using: "dense"`: Qdrant averages the stored dense vectors of the positive points and searches with that centroid. That is the whole combine step; no vectors cross the wire. Supported on our Qdrant 1.17.1 (`docker-compose.dev.yml`).
- Excluding the source: `filter.must_not: [{has_id: ids}]` alongside the existing tenant filter (`Qdrant.build_tenant_filter/1`, which carries `user_id`, the vault filter, and the HMAC/date filters).
- A positive point without a `dense` vector makes Qdrant reject the request, hence the `dense_indexed_hash` pre-check, which turns that case into a fixable error before any Qdrant call.

**Files:**
- Modify: `lib/engram/indexing.ex` (extract public `point_ids_for_note/1` from `delete_points_for_note/1`, ~:623)
- Modify: `lib/engram/vector/qdrant.ex` (add `recommend/3`, `recommend_body/2` after `hybrid_search_body/3`)
- Modify: `lib/engram/search.ex` (add `similar/4`; `run_legs(:similar, ...)`; rerank only for a text query)
- Modify: `lib/engram/mcp/handlers.ex` (`search_kind/1` gains `:similar`; both `search_notes` clauses gain a `:similar` branch; new `similar_source/3`, `stored_points/2`)
- Modify: `lib/engram/mcp/tools.ex` (`search_notes_def/0`: `similar_to`, description)
- Test: `test/engram/vector/qdrant_recommend_test.exs`, `test/engram/mcp/handlers_similar_test.exs` (new)
- Regenerate: `mcp-tools.json`

**Interfaces:**
- Consumes: `search_kind/1`, `render_search/2`, `build_search_opts/1` (Task 5 and existing).
- Produces:
  - `Engram.Indexing.point_ids_for_note(note) :: [String.t()]` (tenant-scoped, ordered by position, nils dropped)
  - `Engram.Vector.Qdrant.recommend(col \\ nil, point_ids :: [String.t()], search_opts) :: {:ok, [map()]} | {:error, term()}` and `recommend_body(point_ids, search_opts) :: map()`
  - `Engram.Search.similar(user, vault | nil, point_ids :: [String.t()], opts) :: {:ok, [map()]} | {:error, term()}`: same vault guard and cross-vault entitlement as `search/4`, NO `spend_search_budget/1`, no embed, results grouped per note (`group_by_note: true`), same filters.
  - Tool: `similar_to: String.t()` (note path). With `query` non-blank: error. `mode` ignored. Filters, `limit`, `diversity` apply. Source resolution: in the given vault; in cross-vault mode, the one accessible vault holding that path (error naming `vault_id` if several do). Results searched across the same scope a query search would use.

Decision: no `ai_searches_per_day` charge at all. The budget meters Voyage spend (see the comment above `spend_search_budget/1` in `search.ex`); `similar_to` makes no Voyage call.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/vector/qdrant_recommend_test.exs
defmodule Engram.Vector.QdrantRecommendTest do
  use ExUnit.Case, async: true

  alias Engram.Vector.Qdrant

  test "averages the positive points, excludes them, keeps the tenant filter" do
    body = Qdrant.recommend_body(["p1", "p2"], user_id: "u1", vault_id: "v1", limit: 7)

    assert body.query == %{recommend: %{positive: ["p1", "p2"], strategy: "average_vector"}}
    assert body.using == "dense"
    assert body.limit == 7
    assert body.with_payload == true
    assert body.filter.must_not == [%{has_id: ["p1", "p2"]}]
    assert %{key: "user_id", match: %{value: "u1"}} in body.filter.must
    assert %{key: "vault_id", match: %{value: "v1"}} in body.filter.must
  end
end
```

```elixir
# test/engram/mcp/handlers_similar_test.exs
defmodule Engram.MCP.HandlersSimilarTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.MCP.Handlers
  alias Engram.Notes
  alias Engram.Notes.Chunk

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    expect(Engram.MockEmbedder, :embed_texts, 0, fn _t, _o -> flunk("similar_to must not embed") end)
    %{bypass: bypass, user: user, vault: vault}
  end

  defp note_with_points(user, vault, path, n, embedded?) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# #{path}\n\nbody", "mtime" => 1.0})

    ids =
      for pos <- 0..(n - 1)//1 do
        id = Ecto.UUID.generate()

        {:ok, _} =
          Engram.Repo.with_tenant(user.id, fn ->
            %Chunk{}
            |> Chunk.changeset(%{
              note_id: note.id, user_id: user.id, vault_id: vault.id,
              position: pos, char_start: 0, char_end: 4, qdrant_point_id: id
            })
            |> Engram.Repo.insert!()
          end)

        id
      end

    if embedded? do
      Engram.Repo.update_all(
        from(x in Engram.Notes.Note, where: x.id == ^note.id),
        [set: [dense_indexed_hash: "h"]],
        skip_tenant_check: true
      )
    end

    ids
  end

  defp hit(user, vault, point_id) do
    {:ok, enc} =
      Engram.Crypto.encrypt_qdrant_payload(
        %{text: "body", title: "O", heading_path: "O"}, user, "engram_notes", point_id
      )

    %{
      "id" => point_id,
      "score" => 0.8,
      "payload" => %{
        "text" => enc.text, "title" => enc.title, "heading_path" => enc.heading_path,
        "text_nonce" => enc.text_nonce, "title_nonce" => enc.title_nonce,
        "heading_path_nonce" => enc.heading_path_nonce, "aad_version" => enc.aad_version,
        "user_id" => to_string(user.id), "vault_id" => to_string(vault.id)
      }
    }
  end

  defp respond(conn, points) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => %{"points" => points}}))
  end

  test "recommends from the source's stored points and excludes them", %{bypass: bypass, user: u, vault: v} do
    s_ids = note_with_points(u, v, "S.md", 2, true)
    [o_id] = note_with_points(u, v, "O.md", 1, true)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["using"] == "dense"
      assert Enum.sort(json["query"]["recommend"]["positive"]) == Enum.sort(s_ids)
      assert json["query"]["recommend"]["strategy"] == "average_vector"
      assert [%{"has_id" => excluded}] = json["filter"]["must_not"]
      assert Enum.sort(excluded) == Enum.sort(s_ids)
      assert %{"key" => "vault_id", "match" => %{"value" => to_string(v.id)}} in json["filter"]["must"]
      respond(conn, [hit(u, v, o_id)])
    end)

    assert {:ok, _text, %{"results" => [r]}} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "S.md", "query" => nil})

    assert r["source_path"] == "O.md"
  end

  test "does not spend the search budget", %{bypass: bypass, user: u, vault: v} do
    note_with_points(u, v, "S.md", 1, true)
    insert(:user_limit_override, user: u, key: "ai_searches_per_day", value: %{"v" => 0})
    assert {:error, :search_cap_exceeded, 0} = Engram.Search.search(u, v, "anything")

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", &respond(&1, []))
    assert {:ok, "No results found.", %{"results" => []}} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "S.md"})
  end

  # Review Focus 2: no Bypass expectation, so any Qdrant call fails the test.
  test "a note with no dense vectors is a fixable error, not a search", %{user: u, vault: v} do
    note_with_points(u, v, "Sparse.md", 2, false)
    note_with_points(u, v, "Empty.md", 0, true)

    for path <- ["Sparse.md", "Empty.md"] do
      assert {:error, msg} = Handlers.handle("search_notes", u, v, %{"similar_to" => path})
      assert msg =~ "#{path} has no stored embedding yet"
      assert msg =~ "use query"
    end
  end

  test "query and similar_to together, a blank similar_to, and a missing note are fixable",
       %{user: u, vault: v} do
    assert {:error, "Pass query or similar_to, not both"} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "S.md", "query" => "x"})

    assert {:error, "similar_to must be a note path"} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => " "})

    assert {:error, "Note not found: Gone.md"} =
             Handlers.handle("search_notes", u, v, %{"similar_to" => "Gone.md"})
  end

  test "cross-vault: the source is found in its one vault and results span all", %{bypass: bypass, user: u, vault: v} do
    other = insert(:vault, user: u)
    note_with_points(u, v, "S.md", 1, true)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      must = Jason.decode!(body)["filter"]["must"]
      assert %{"key" => "vault_id", "match" => %{"any" => ids}} = Enum.find(must, &(&1["key"] == "vault_id"))
      assert Enum.sort(ids) == Enum.sort([to_string(v.id), to_string(other.id)])
      respond(conn, [])
    end)

    assert {:ok, _, _} = Handlers.handle("search_notes", u, {:cross_vault, [v, other]}, %{"similar_to" => "S.md"})
  end

  test "cross-vault: a path held by two vaults asks for vault_id", %{user: u, vault: v} do
    other = insert(:vault, user: u)
    note_with_points(u, v, "S.md", 1, true)
    note_with_points(u, other, "S.md", 1, true)

    assert {:error, msg} = Handlers.handle("search_notes", u, {:cross_vault, [v, other]}, %{"similar_to" => "S.md"})
    assert msg =~ "S.md exists in 2 vaults"
    assert msg =~ "pass vault_id"
  end

  test "schema declares similar_to" do
    {:ok, tool} = Engram.MCP.Tools.get("search_notes")
    assert tool.inputSchema["properties"]["similar_to"]["type"] == "string"
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mise exec -- mix test test/engram/vector/qdrant_recommend_test.exs test/engram/mcp/handlers_similar_test.exs`
Expected: FAIL, `Qdrant.recommend_body/2 is undefined`; the handler treats `similar_to` as absent and lists recent notes.

- [ ] **Step 3: Implement**

`lib/engram/indexing.ex`, replace the read inside `delete_points_for_note/1` and expose it:

```elixir
  @doc """
  Qdrant point ids recorded on `note`'s chunk rows, in chunk order.
  Tenant-scoped: unscoped, RLS filters this read to [] silently.
  """
  @spec point_ids_for_note(map()) :: [String.t()]
  def point_ids_for_note(note) do
    {:ok, point_ids} =
      Repo.with_tenant(note.user_id, fn ->
        Chunk
        |> where([c], c.note_id == ^note.id)
        |> order_by([c], c.position)
        |> select([c], c.qdrant_point_id)
        |> Repo.all()
      end)

    Enum.reject(point_ids, &is_nil/1)
  end

  defp delete_points_for_note(note) do
    Qdrant.delete_points(collection(), point_ids_for_note(note))
  end
```

Keep the existing comment block above `delete_points_for_note/1`.

`lib/engram/vector/qdrant.ex`, after `hybrid_search_body/3`:

```elixir
  @doc """
  Points similar to the given stored points: Qdrant averages their dense
  vectors (`average_vector`) and searches with the centroid. No embed call.
  The given points are excluded from the results. Same options as `search/3`.
  """
  def recommend(col \\ nil, point_ids, search_opts) do
    col = col || collection()

    instrument(:recommend, fn ->
      do_search(col, [json: recommend_body(point_ids, search_opts)] ++ req_opts(:search))
    end)
  end

  @doc false
  def recommend_body(point_ids, search_opts) do
    %{
      query: %{recommend: %{positive: point_ids, strategy: "average_vector"}},
      using: "dense",
      filter: Map.put(build_tenant_filter(search_opts), :must_not, [%{has_id: point_ids}]),
      limit: Keyword.get(search_opts, :limit, 5),
      with_payload: true
    }
    |> then(fn b ->
      case quantization_params(search_opts) do
        nil -> b
        params -> Map.put(b, :params, params)
      end
    end)
    |> maybe_with_vector(search_opts)
  end
```

`lib/engram/search.ex`:

```elixir
  @doc """
  Notes similar to a stored note, from that note's chunk points (`point_ids`)
  via Qdrant recommend. Same vault guard, entitlement, filters and grouping as
  `search/4`, but NO `ai_searches_per_day` spend: that budget meters the query
  embed, and this path makes none. Results are grouped per note.
  """
  def similar(user, vault, point_ids, opts \\ []) when is_list(point_ids) and point_ids != [] do
    with :ok <- vault_ids_present?(vault, opts),
         :ok <- cross_vault_entitlement(user, opts) do
      do_search_instrumented(
        user,
        vault,
        {:similar, point_ids},
        Keyword.merge(opts, mode: :similar, group_by_note: true)
      )
    end
  end
```

In `do_search/4`, change `rerank_for_user? = reranker_active?() and profile.reranker` to:

```elixir
    # A similar_to query is `{:similar, ids}`, not text: nothing to rerank against.
    rerank_for_user? = reranker_active?() and profile.reranker and is_binary(query)
```

Add before the `run_legs(_invalid_mode, ...)` catch-all:

```elixir
  # similar_to: the source note's stored dense vectors, averaged by Qdrant.
  defp run_legs(:similar, _user, {:similar, point_ids}, search_opts, _profile),
    do: Qdrant.recommend(collection(), point_ids, search_opts)
```

`lib/engram/mcp/handlers.ex`, replace `search_kind/1`:

```elixir
  defp search_kind(args) do
    similar = args["similar_to"]
    blank? = String.trim(args["query"] || "") == ""

    cond do
      is_binary(similar) and not blank? ->
        {:error, "Pass query or similar_to, not both"}

      is_binary(similar) and String.trim(similar) == "" ->
        {:error, "similar_to must be a note path"}

      is_binary(similar) ->
        {:ok, :similar}

      blank? ->
        case Enum.find(@search_filters, &(not is_nil(args[&1]))) do
          nil -> {:ok, :recent}
          p -> {:error, "#{p} needs a query or similar_to; omit it to list recently updated notes"}
        end

      true ->
        {:ok, :query}
    end
  end
```

Add a `{:ok, :similar}` branch to each `search_notes` clause. Cross-vault clause (the `opts` keyword list moves above the `case` so both branches share it):

```elixir
      {:ok, :similar} ->
        with {:ok, note} <- similar_source(user, vaults, args["similar_to"]),
             {:ok, ids} <- stored_points(note, args["similar_to"]) do
          render_search(Search.similar(user, nil, ids, opts), names)
        end
```

Single-vault clause:

```elixir
      {:ok, :similar} ->
        with {:ok, note} <- similar_source(user, [vault], args["similar_to"]),
             {:ok, ids} <- stored_points(note, args["similar_to"]) do
          render_search(Search.similar(user, vault, ids, build_search_opts(args)), %{})
        end
```

Helpers:

```elixir
  # The source must be unambiguous: the same path can exist in several vaults.
  defp similar_source(user, vaults, path) do
    hits = for v <- vaults, {:ok, note} <- [Notes.get_note(user, v, path)], do: {note, v}

    case hits do
      [{note, _v}] ->
        {:ok, note}

      [] ->
        {:error, "Note not found: #{path}"}

      many ->
        names = Enum.map_join(many, ", ", fn {_n, v} -> v.name end)
        {:error, "#{path} exists in #{length(many)} vaults (#{names}); pass vault_id to pick one"}
    end
  end

  # `dense_indexed_hash` is nil unless the last index pass wrote dense vectors
  # (EmbedNote.stamp_embed_hash/3). Qdrant rejects a recommend whose positive
  # point has no dense vector, so refuse here with a message the caller can act on.
  defp stored_points(%{dense_indexed_hash: nil}, path), do: {:error, not_embedded(path)}

  defp stored_points(note, path) do
    case Engram.Indexing.point_ids_for_note(note) do
      [] -> {:error, not_embedded(path)}
      ids -> {:ok, ids}
    end
  end

  defp not_embedded(path),
    do:
      "#{path} has no stored embedding yet (it may be new, empty, or not embedded on " <>
        "your plan); try again later, or use query instead"
```

`tools.ex`, `search_notes_def/0`:
- description:
  ```elixir
  "Search your personal knowledge base. Finds relevant notes using semantic " <>
    "search. Searches across ALL your vaults by default; pass vault_id to limit " <>
    "to one. Omit query to list the most recently updated notes instead. Pass " <>
    "similar_to with a note path, instead of query, to find notes like that one. " <>
    "Use when the user asks about their notes, vault, knowledge, or memory."
  ```
- new property:
  ```elixir
  "similar_to" => %{
    "type" => "string",
    "description" =>
      "Path of a note, e.g. \"Projects/Alpha.md\": return notes similar to it, using " <>
        "its stored embedding (no query needed). Do not combine with query. The note " <>
        "itself is excluded; filters still apply."
  }
  ```

- [ ] **Step 4: Run to verify they pass**

Run: `mise exec -- mix test test/engram/vector/qdrant_recommend_test.exs test/engram/mcp/handlers_similar_test.exs test/engram/mcp/handlers_recent_test.exs test/engram/search_test.exs test/engram/search_hybrid_test.exs test/engram/search/cross_vault_gate_test.exs test/engram/indexing_test.exs`
Expected: PASS. (If `test/engram/indexing_test.exs` does not exist, run `mise exec -- mix test test/engram/indexing*` instead.)

- [ ] **Step 5: Regenerate snapshot and commit**

```bash
mise exec -- mix engram.mcp.tools_json
git add lib/engram/indexing.ex lib/engram/vector/qdrant.ex lib/engram/search.ex lib/engram/mcp/handlers.ex lib/engram/mcp/tools.ex mcp-tools.json test/engram/vector/qdrant_recommend_test.exs test/engram/mcp/handlers_similar_test.exs
git commit -m "feat(mcp): search_notes similar_to finds notes like a given note

Uses the note's stored chunk vectors via Qdrant recommend (average_vector).
No embed call and no search-budget charge.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SUoP129aB16738p5qJLweA"
```

---

### Task 7: e2e for insert_section and include_links, lint gate, PR

**Files:**
- Create: `e2e/tests/api_only/test_100_mcp_parity_params.py`
- Check: `mcp-tools.json` (already regenerated per task)

**Interfaces:**
- Consumes: `api_sync` fixture, `ApiClient.with_vault/1`, `create_note/2`, `wait_for_note/1`, `get_note/1`, `mcp_call/2` (`e2e/helpers/api.py`), same pattern as `test_99_mcp_retired_aliases.py`.

- [ ] **Step 1: Write the e2e tests**

```python
"""Test 100: MCP parity params (#1793) against the real stack.

insert_section writes through the normal save path and lands where a reader
expects; include_links reads the note_links graph the indexing job builds, so
it polls until extraction has run.
"""

from __future__ import annotations

import time
import uuid

import pytest


@pytest.fixture(scope="module")
def scoped(api_sync):
    vaults = api_sync.list_vaults()
    assert vaults, "api_sync user has no vaults"
    vault_id = vaults[0]["id"]
    return api_sync.with_vault(vault_id), vault_id


def test_insert_section_end_and_start(scoped):
    api, vault_id = scoped
    path = f"E2E/McpParity100Insert-{uuid.uuid4().hex[:8]}.md"
    api.create_note(path, "# Insert\n\n## Todo\n\n- a\n\n### Sub\n\n- s\n\n## Done\n\n- x\n")
    api.wait_for_note(path)

    for position, text in (("end", "- last"), ("start", "- first")):
        resp, status = api.mcp_call(
            "edit_note",
            {"path": path, "mode": "insert_section", "heading": "Todo",
             "content": text, "position": position, "vault_id": vault_id},
        )
        assert status == 200
        result = resp["result"]
        assert result["isError"] is False, result
        assert result["structuredContent"]["mode"] == "insert_section"

    content = api.get_note(path)["content"]
    assert "## Todo\n- first\n" in content
    assert "### Sub\n\n- s\n- last\n\n## Done" in content


def test_insert_section_missing_heading_writes_nothing(scoped):
    api, vault_id = scoped
    path = f"E2E/McpParity100Missing-{uuid.uuid4().hex[:8]}.md"
    api.create_note(path, "# Missing\n\n## Todo\n\n- a\n")
    api.wait_for_note(path)
    before = api.get_note(path)["content"]

    resp, status = api.mcp_call(
        "edit_note",
        {"path": path, "mode": "insert_section", "heading": "Nope",
         "content": "- y", "vault_id": vault_id},
    )
    assert status == 200
    assert resp["result"]["isError"] is True
    assert api.get_note(path)["content"] == before


def test_get_notes_include_links(scoped):
    api, vault_id = scoped
    tag = uuid.uuid4().hex[:8]
    target = f"E2E/McpParity100Target-{tag}.md"
    source = f"E2E/McpParity100Source-{tag}.md"
    api.create_note(target, f"# Target\n\nsee [[Ghost-{tag}]]")
    api.create_note(source, f"# Source\n\nsee [[McpParity100Target-{tag}]]")
    api.wait_for_note(target)
    api.wait_for_note(source)

    # Link extraction runs in the indexing job, so poll.
    deadline = time.monotonic() + 60
    note = None
    while time.monotonic() < deadline:
        resp, status = api.mcp_call(
            "get_notes",
            {"paths": [target, f"E2E/Nope-{tag}.md"], "include_links": True, "vault_id": vault_id},
        )
        assert status == 200
        result = resp["result"]
        assert result["isError"] is False, result
        note, missing = result["structuredContent"]["notes"]
        if source in note.get("backlinks", []) and note.get("unresolved"):
            break
        time.sleep(2)

    assert source in note["backlinks"], note
    assert note["unresolved"] == [f"Ghost-{tag}"], note
    assert missing == {"path": f"E2E/Nope-{tag}.md", "found": False}
```

- [ ] **Step 2: Run the e2e file against a local CI stack**

Run (from the workspace root): `make ci-up`, then from the backend worktree `cd e2e && pytest tests/api_only/test_100_mcp_parity_params.py -v`, then `make ci-down`. If the local stack is unavailable, record that and rely on the PR's e2e jobs; do not skip the file.
Expected: 3 passed.

- [ ] **Step 3: Full local gate**

```bash
mise exec -- mix format
mise exec -- mix compile --warnings-as-errors
mise exec -- mix credo --strict
mise exec -- mix dialyzer
mise exec -- mix test test/engram/mcp test/engram/search_test.exs test/engram/search_hybrid_test.exs test/engram/search test/engram/vector test/engram/notes_recent_test.exs test/engram/links_test.exs test/engram_web/controllers/mcp_controller_test.exs test/engram_web/controllers/mcp_listings_structured_output_test.exs
mise exec -- mix engram.mcp.tools_json && git diff --exit-code mcp-tools.json
npx -y mcp-tdqs@0.2.0 lint --file mcp-tools.json --server-name engram --fail-on warning
```

Expected: every command exits 0 (run each on its own; do not pipe a gate command). If TDQS warns, fix the named description or parameter text in `tools.ex`, regenerate, and re-run; never loosen the `--fail-on` level.

- [ ] **Step 4: Commit**

```bash
git add e2e/tests/api_only/test_100_mcp_parity_params.py
git commit -m "test(e2e): insert_section and include_links over MCP

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SUoP129aB16738p5qJLweA"
```

- [ ] **Step 5: Push and open the PR (the controller does this step, after review)**

```bash
mise exec -- git push -u origin feat/mcp-parity-params
gh pr create -R engram-app/Engram --title "feat(mcp): parity params for search, read and edit" --body "Closes #1793

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01SUoP129aB16738p5qJLweA"
```

---

## Self-review notes

- Spec coverage (#1793): insert_section (Tasks 1, 2), similar_to (Task 6), recent notes (Task 5), include_links (Task 4), section/outline (Tasks 1, 3); e2e for insert_section and include_links (Task 7); TDQS lint and snapshot (every tools.ex task, gate in Task 7); tool count unchanged (no new tool; `tools_aliases_test.exs` run in Task 2).
- Save path: insert_section uses `rmw_upsert/5`; replace_section keeps its existing `Notes.upsert_note/4` call. No other writes.
- Null handling: tested for `position` (Task 2), `section`/`outline` (Task 3), `include_links` (Task 4), `query` and filters (Task 5), `query: nil` with `similar_to` (Task 6).
- Deliberate decisions, each stated in its task: `section` is one path and a missing heading is an error; `outline` drops `content`; links are path lists and attachment links are excluded; recent listing ignores `mode`/`diversity` but refuses filters and ignores the index cap; `similar_to` charges no budget, groups per note, and resolves an ambiguous cross-vault path by asking for `vault_id`; fenced/frontmatter `#` lines stop counting as headings for `replace_section` too.
