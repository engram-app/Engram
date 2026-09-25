# MCP Tool Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Score every MCP tool-surface change in CI with TDQS, fix the weakest tool descriptions, consolidate 21 tools to 17 without breaking existing clients, and add "recent notes" and backlinks as parameters.

**Architecture:** One shared function (`Engram.MCP.Tools.wire_list/0`) produces the exact `tools/list` payload; the controller serves it and a mix task snapshots it to a committed `mcp-tools.json` that CI drift-checks and lints with TDQS (the same committed-artifact pattern as `openapi.json`). Consolidation keeps retired tool names callable as hidden aliases resolved by `Tools.get/1` but never listed by `Tools.list/0`. New capabilities ride on existing tools as parameters.

**Tech Stack:** Elixir 1.17 / Phoenix, ExUnit + Mox, GitHub Actions on the self-hosted isolated pool, Node 22 + `mcp-tdqs@0.2.0` (npx), Python e2e harness.

**Spec:** Engram vault, `50 Engineering/_Superpowers Specs/2026-09-25-mcp-tool-surface-design.md` (read it with the engram MCP `get_note`). Source discussion: engram-app/Engram#1767 and its three comments.

## Global Constraints

- Run every `mix` command and every `git push` through `mise exec --` (PATH erl is OTP 26, CI is OTP 27).
- Branch prefixes must be on the verify.yml allowlist: use `feat/` or `fix/` (a `ci/` branch gets no CI run at all).
- One PR per phase, in order 1, 2, 3, 4. Each PR ships on its own.
- NO version bumps in `mix.exs`, `server.json` or anywhere: release-please owns versions.
- Conventional commits; the PR title is the changelog line, so user-visible changes are `feat(mcp):` / `fix(mcp):`.
- No em dashes in any user-facing copy (tool descriptions, docs).
- Before every push: `mise exec -- mix format`, `mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix credo --strict`, `mise exec -- mix dialyzer` (dialyzer is CI-gated but stays a local habit), and the touched test files.
- TDD: write the failing test first, watch it fail, then implement. Never loosen or delete an existing assertion to go green; if an old assertion encodes behavior this plan intentionally removes, replace it with an assertion of the new behavior and say so in the commit body.
- Tool annotations stay honest per tool: merging only happens between tools that share `{readOnlyHint, destructiveHint}`.
- `mcp-tdqs` pinned to `0.2.0`; score model pinned to `claude-haiku-4-5-20251001`.
- Tool count after phase 3: exactly 17 listed tools.

## Review Focus

1. **Cross-mode parameters on `edit_note`**: an agent passes `heading` with `mode: "replace_text"`. Expect a fixable `isError` naming the stray parameter, never a silent partial edit. Test owned by Task 3.3.
2. **`append_to_note` with `position: "start"`** on a note with frontmatter, a note without frontmatter, and an empty note. Expect the text inserted directly after the closing `---` fence, at the very top, and as the body respectively, with frontmatter bytes untouched. Test owned by Task 3.4.
3. **`search_notes` with `query: ""` or whitespace-only** (not just absent). Expect the same "recent notes" listing as an absent query, never a Voyage embed call or a search-budget charge. Test owned by Task 4.1.
4. **`get_notes(include_backlinks: true)` with a path that is not found.** Expect `found: false` for that entry, no `backlinks` key on it, and the found entries still carrying backlinks. Test owned by Task 4.2.
5. **An old client with a cached `tools/list` calling `get_note(source_path: ...)` or `set_vault` after phase 3.** Expect it to work exactly as before (same `structuredContent`), plus a one-line deprecation hint in the text, and telemetry tagged with the old tool name (not `:unknown`). Test owned by Task 3.2.

---

# Phase 1: TDQS in CI (PR 1, branch `feat/mcp-tdqs-ci`)

### Task 1.1: Shared wire mapping `Tools.wire_list/0`

**Files:**
- Modify: `lib/engram/mcp/tools.ex` (add `wire_list/0` after `list/0`, around line 101)
- Modify: `lib/engram_web/controllers/mcp_controller.ex:583-603` (`dispatch(_conn, "tools/list", _)`)
- Test: `test/engram/mcp/tools_wire_list_test.exs` (new)

**Interfaces:**
- Produces: `Engram.MCP.Tools.wire_list() :: [map()]`, string-keyed maps with `"name"`, `"title"`, `"description"`, `"inputSchema"`, `"annotations"`, and `"outputSchema"` when the tool declares one. Exactly what `tools/list` returns.

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/mcp/tools_wire_list_test.exs
defmodule Engram.MCP.ToolsWireListTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.MCP.Tools

  test "wire_list/0 renders every listed tool with string keys and no handler" do
    wire = Tools.wire_list()

    assert length(wire) == length(Tools.list())

    for t <- wire do
      assert Map.keys(t) -- ["name", "title", "description", "inputSchema", "annotations", "outputSchema"] == []
      assert is_binary(t["name"]) and is_binary(t["description"])
      refute Map.has_key?(t, "handler")
    end
  end

  test "wire_list/0 is byte-for-byte what tools/list serves" do
    user = insert(:user)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "wire-list")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    served = json_response(conn, 200)["result"]["tools"]
    assert served == Tools.wire_list() |> Jason.encode!() |> Jason.decode!()
  end
end
```

Before writing the second test, copy the exact auth setup from `test/engram_web/controllers/mcp_controller_test.exs:8-50` (its `setup` and `jsonrpc/3` helper) instead of the `create_api_key` call above if the helper names differ; the assertion is what matters.

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/engram/mcp/tools_wire_list_test.exs`
Expected: FAIL, `function Engram.MCP.Tools.wire_list/0 is undefined`.

- [ ] **Step 3: Implement `wire_list/0` and use it in the controller**

In `lib/engram/mcp/tools.ex`, after `list/0`:

```elixir
  @doc """
  The exact `tools/list` payload: what `McpController` serves and what
  `mix engram.mcp.tools_json` snapshots for TDQS. One function so the two
  cannot drift.
  """
  @spec wire_list() :: [map()]
  def wire_list do
    Enum.map(list(), fn t ->
      base = %{
        "name" => t.name,
        "title" => t.title,
        "description" => t.description,
        "inputSchema" => t.inputSchema,
        "annotations" => t.annotations
      }

      # Only for converted tools (#1660). An `outputSchema` a tool cannot
      # honour is worse than none: a client generates types from it.
      case t[:outputSchema] do
        nil -> base
        schema -> Map.put(base, "outputSchema", schema)
      end
    end)
  end
```

In `lib/engram_web/controllers/mcp_controller.ex`, replace the body of `dispatch(_conn, "tools/list", _params)`:

```elixir
  defp dispatch(_conn, "tools/list", _params) do
    {:ok, %{"tools" => Tools.wire_list()}}
  end
```

- [ ] **Step 4: Run the new test and the existing MCP controller tests**

Run: `mise exec -- mix test test/engram/mcp/tools_wire_list_test.exs test/engram_web/controllers/mcp_controller_test.exs test/engram_web/controllers/mcp_structured_output_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/mcp/tools.ex lib/engram_web/controllers/mcp_controller.ex test/engram/mcp/tools_wire_list_test.exs
git commit -m "refactor(mcp): one wire_list/0 for the tools/list payload"
```

### Task 1.2: `mix engram.mcp.tools_json` and the committed snapshot

**Files:**
- Create: `lib/mix/tasks/engram.mcp.tools_json.ex`
- Create: `mcp-tools.json` (generated, repo root)
- Modify: `ci/fingerprint/groups.sh:27` (add `mcp-tools.json` to `lint-config`)
- Test: `test/mix/tasks/engram_mcp_tools_json_test.exs` (new)

**Interfaces:**
- Consumes: `Engram.MCP.Tools.wire_list/0` (Task 1.1).
- Produces: `mix engram.mcp.tools_json [path]`, default path `mcp-tools.json`, writes `{"tools": [...]}` pretty-printed with a trailing newline.

- [ ] **Step 1: Write the failing test**

```elixir
# test/mix/tasks/engram_mcp_tools_json_test.exs
defmodule Mix.Tasks.Engram.Mcp.ToolsJsonTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "writes the tools/list payload to the given path", %{tmp_dir: dir} do
    path = Path.join(dir, "tools.json")
    Mix.Tasks.Engram.Mcp.ToolsJson.run([path])

    decoded = path |> File.read!() |> Jason.decode!()
    assert decoded["tools"] == Engram.MCP.Tools.wire_list() |> Jason.encode!() |> Jason.decode!()
    assert File.read!(path) |> String.ends_with?("\n")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/mix/tasks/engram_mcp_tools_json_test.exs`
Expected: FAIL, `module Mix.Tasks.Engram.Mcp.ToolsJson is not available`.

- [ ] **Step 3: Implement the task**

```elixir
# lib/mix/tasks/engram.mcp.tools_json.ex
defmodule Mix.Tasks.Engram.Mcp.ToolsJson do
  @shortdoc "Writes the MCP tools/list payload to mcp-tools.json"

  @moduledoc """
  Snapshots the exact `tools/list` payload (`Engram.MCP.Tools.wire_list/0`)
  so CI can lint it with TDQS without starting the app or a database.

  Usage: `mix engram.mcp.tools_json [path]` (default `mcp-tools.json`).
  Regenerate and commit whenever a tool definition changes; CI fails when the
  committed file is stale.
  """

  use Mix.Task

  @default_path "mcp-tools.json"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")
    path = List.first(argv) || @default_path
    json = Jason.encode!(%{"tools" => Engram.MCP.Tools.wire_list()}, pretty: true)
    File.write!(path, json <> "\n")
    Mix.shell().info("wrote #{path}")
  end
end
```

- [ ] **Step 4: Run the test, then generate the snapshot**

Run: `mise exec -- mix test test/mix/tasks/engram_mcp_tools_json_test.exs`
Expected: PASS.

Run: `mise exec -- mix engram.mcp.tools_json`
Expected: `wrote mcp-tools.json`, a file with 21 tools.

- [ ] **Step 5: Add the snapshot to the lint fingerprint group**

In `ci/fingerprint/groups.sh`, change the `lint-config` line so an edit to the snapshot alone can never replay a stale lint pass:

```bash
    lint-config) echo ".credo.exs .sobelow-conf .sobelow-skips .formatter.exs .dialyzer_ignore.exs mcp-tools.json" ;;
```

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/engram.mcp.tools_json.ex test/mix/tasks/engram_mcp_tools_json_test.exs mcp-tools.json ci/fingerprint/groups.sh
git commit -m "feat(mcp): snapshot tools/list to mcp-tools.json"
```

### Task 1.3: Drift check + TDQS lint gate in the `lint` job

**Files:**
- Modify: `.github/workflows/verify.yml`, `lint` job, insert after the `Limit-keys lint` step (around line 2896)

**Interfaces:**
- Consumes: `mix engram.mcp.tools_json` (Task 1.2), committed `mcp-tools.json`.

The `lint` job already runs on every push to an allowlisted branch, restores deps and `_build/dev`, is skipped only when its fingerprint (now including `mcp-tools.json`) is unchanged, and is a required check via the `ci` aggregate. So no new job and no paths filter are needed: the fingerprint is the filter.

- [ ] **Step 1: Prove the gate fails first (local red check)**

Temporarily edit one description in `lib/engram/mcp/tools.ex` (e.g. append " x" to `list_tags`), then run the exact commands the CI step will run:

```bash
mise exec -- mix engram.mcp.tools_json /tmp/mcp-tools.generated.json
python3 -c "import json,sys; a=json.load(open('mcp-tools.json')); b=json.load(open('/tmp/mcp-tools.generated.json')); sys.exit(0 if a==b else 1)"; echo "exit=$?"
```

Expected: `exit=1`. Revert the description edit and rerun: expected `exit=0`.

Then prove the lint gate trips on a real defect:

```bash
python3 -c "import json; d=json.load(open('mcp-tools.json')); d['tools'][0]['description']=''; json.dump(d,open('/tmp/bad-tools.json','w'))"
npx -y mcp-tdqs@0.2.0 lint --file /tmp/bad-tools.json --server-name engram --fail-on warning; echo "exit=$?"
npx -y mcp-tdqs@0.2.0 lint --file mcp-tools.json --server-name engram --fail-on warning; echo "exit=$?"
```

Expected: first `exit=1`, second `exit=0` (the spike found 0 errors, 0 warnings, 0 notes on today's 21 tools).

- [ ] **Step 2: Add the steps to verify.yml**

Insert after the `Limit-keys lint` step in the `lint` job:

```yaml
      - name: MCP tools snapshot is fresh
        # mcp-tools.json is the committed tools/list payload TDQS scores
        # (same drift-gate pattern as openapi.json). Regenerate with
        # `mix engram.mcp.tools_json` whenever a tool definition changes.
        run: |
          mix engram.mcp.tools_json /tmp/mcp-tools.generated.json
          python3 - <<'PY'
          import json, sys
          committed = json.load(open("mcp-tools.json"))
          generated = json.load(open("/tmp/mcp-tools.generated.json"))
          if committed != generated:
              print("::error::mcp-tools.json is stale. Run: mix engram.mcp.tools_json")
              sys.exit(1)
          PY

      - uses: actions/setup-node@v7
        # mcp-tdqs needs Node 22+. The e2e-clerk job pins 20 for its own
        # reasons; this job gets its own setup.
        with:
          node-version: '22'

      - name: TDQS lint (MCP tool definitions)
        # Deterministic, no model, no key (TDQS stages 1, 2 and 4). Fails on
        # a missing description, missing annotations, uncovered parameters,
        # or a shadowing name. Scoring with a model is the separate
        # mcp-tdqs-score workflow (report-only).
        run: npx -y mcp-tdqs@0.2.0 lint --file mcp-tools.json --server-name engram --fail-on warning
```

- [ ] **Step 3: Push and confirm CI**

```bash
mise exec -- mix format && mise exec -- mix credo --strict
mise exec -- git push -u origin feat/mcp-tdqs-ci
gh pr checks --watch
```

Expected: `lint` passes and its log shows `TDQS lint · engram · 21 tools` with no findings.

- [ ] **Step 4: Commit** (before the push above if you split the work)

```bash
git add .github/workflows/verify.yml
git commit -m "ci(mcp): gate tool definitions on TDQS lint and snapshot drift"
```

### Task 1.4: Report-only TDQS score workflow

**Files:**
- Create: `.github/workflows/mcp-tdqs-score.yml`

**Interfaces:**
- Consumes: committed `mcp-tools.json`; repo secret `ANTHROPIC_API_KEY` (a human adds it once: `gh secret set ANTHROPIC_API_KEY -R engram-app/Engram`).

Trigger is `push` (branch allowlist) with a paths filter, NOT `pull_request`: every workflow here runs on the self-hosted pool and deliberately refuses fork-PR code (see the comment at the top of `verify.yml`). It is not a required check, so a paths filter is safe.

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/mcp-tdqs-score.yml
name: MCP TDQS score

# Model-graded TDQS score of the committed MCP tool definitions. REPORT-ONLY
# for the first 5 runs (continue-on-error) while run-to-run variance is
# measured; then flip to gating per docs/context/mcp-tdqs-baseline.md.
# ~22 model calls / ~52K tokens per run on Haiku 4.5 (about $0.12).
on:
  push:
    branches: [main, "feat/**", "fix/**", "refactor/**", "docs/**"]
    paths: ["mcp-tools.json"]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: mcp-tdqs-score-${{ github.ref }}
  cancel-in-progress: true

jobs:
  score:
    runs-on: [self-hosted, linux, x64, isolated]
    timeout-minutes: 15
    continue-on-error: true
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-node@v7
        with:
          node-version: '22'

      - name: Score with TDQS
        env:
          TDQS_BASE_URL: https://api.anthropic.com/v1/
          TDQS_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          TDQS_MODEL: claude-haiku-4-5-20251001
          # Anthropic's OpenAI-compatible endpoint requires max_tokens; TDQS
          # sends none. Merged into every request.
          TDQS_REQUEST_OVERRIDES: '{"max_tokens":4096}'
        run: |
          npx -y mcp-tdqs@0.2.0 score --file mcp-tools.json --format markdown --output tdqs-report.md
          npx -y mcp-tdqs@0.2.0 score --file mcp-tools.json --format json --output tdqs-report.json

      - name: Job summary
        if: always()
        run: |
          if [ -f tdqs-report.md ]; then cat tdqs-report.md >> "$GITHUB_STEP_SUMMARY"; fi

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: tdqs-report
          path: tdqs-report.*
```

Note: that runs the model twice. If the CLI supports one run with both outputs, prefer `--format json --output tdqs-report.json` only and render the summary from JSON; check `npx -y mcp-tdqs@0.2.0 score --help` first and keep one model run if possible.

- [ ] **Step 2: Verify the endpoint accepts TDQS's request shape (one call, local)**

```bash
export TDQS_BASE_URL=https://api.anthropic.com/v1/ TDQS_MODEL=claude-haiku-4-5-20251001 TDQS_REQUEST_OVERRIDES='{"max_tokens":4096}'
read -rs TDQS_API_KEY && export TDQS_API_KEY
python3 -c "import json; d=json.load(open('mcp-tools.json')); json.dump({'tools':d['tools'][:1]},open('/tmp/one.json','w'))"
npx -y mcp-tdqs@0.2.0 score --file /tmp/one.json --format text; echo "exit=$?"
```

Expected: `exit=0` with one tool scored. If exit 2 with a request-shape error, switch the workflow to OpenRouter (`TDQS_BASE_URL=https://openrouter.ai/api/v1`, `TDQS_MODEL=anthropic/claude-haiku-4.5`, secret `OPENROUTER_API_KEY`, overrides `{"reasoning":{"enabled":false}}`) and record that in the baseline doc.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/mcp-tdqs-score.yml
git commit -m "ci(mcp): report-only TDQS model score on tool changes"
```

### Task 1.5: Baseline + variance record

**Files:**
- Create: `docs/context/mcp-tdqs-baseline.md`
- Modify: `AGENTS.md` (context-doc index, one trigger line)

- [ ] **Step 1: Score main three times** (after Task 1.4's secret exists): run the workflow 3 times with `gh workflow run mcp-tdqs-score.yml --ref feat/mcp-tdqs-ci`, download each `tdqs-report.json` artifact.

- [ ] **Step 2: Write the doc** with: model + endpoint used, the three overall scores and tiers, the per-tool spread (max minus min per tool, per dimension), the gating rule chosen (server `--fail-under B` and "overall must not drop more than 0.3 below this baseline", or a wider margin if the measured spread exceeds 0.3), and the one-line note that Glama's A 4.1 is from an undisclosed model and is not comparable. Add to `AGENTS.md`:

```markdown
- Changing an MCP tool definition, or the TDQS lint/score job is red (regenerate `mcp-tools.json`; score baseline and gating rule) → `docs/context/mcp-tdqs-baseline.md`
```

- [ ] **Step 3: Commit, open PR 1**

```bash
git add docs/context/mcp-tdqs-baseline.md AGENTS.md
git commit -m "docs(context): TDQS baseline and gating rule for MCP tools"
mise exec -- git push
gh pr create --title "feat(mcp): gate MCP tool definitions on TDQS" --body "Implements phase 1 of the MCP tool surface spec. Refs #1767"
```

---

# Phase 2: Description rewrites, no renames (PR 2, branch `feat/mcp-tool-descriptions`)

### Task 2.1: Sibling-aware descriptions for the eight weakest tools

**Files:**
- Modify: `lib/engram/mcp/tools.ex` (the `description:` of `write_note_def` ~line 640, `patch_note_def` ~694, `append_to_note_def` ~667, `update_section_def` ~726, `delete_note_def`, `list_folder_def` ~404, `list_vaults_def` ~161, `rename_note_def`, `rename_folder_def`)
- Modify: `mcp-tools.json` (regenerated)
- Test: `test/engram/mcp/tools_descriptions_test.exs` (new)

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/mcp/tools_descriptions_test.exs
defmodule Engram.MCP.ToolsDescriptionsTest do
  # Guards the TDQS Usage Guidelines fix: each overlapping tool names the
  # sibling to use for the cases it does not cover.
  use ExUnit.Case, async: true

  alias Engram.MCP.Tools

  @siblings %{
    "write_note" => ~w(append_to_note patch_note create_note),
    "patch_note" => ~w(update_section append_to_note write_note),
    "update_section" => ~w(patch_note append_to_note),
    "append_to_note" => ~w(patch_note write_note),
    "delete_note" => ~w(delete_folder rename_note),
    "list_folder" => ~w(list_folders search_notes),
    "list_vaults" => ~w(vault_id),
    "rename_note" => ~w(rename_folder move_attachment),
    "rename_folder" => ~w(rename_note)
  }

  for {tool, names} <- @siblings, name <- names do
    test "#{tool} description names #{name}" do
      desc = Enum.find(Tools.list(), &(&1.name == unquote(tool))).description
      assert desc =~ unquote(name)
    end
  end

  test "no description uses an em dash" do
    for t <- Tools.list(), do: refute(t.description =~ "—", "#{t.name} has an em dash")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/engram/mcp/tools_descriptions_test.exs`
Expected: FAIL on most `names ...` cases.

- [ ] **Step 3: Replace the descriptions** with exactly these strings:

```elixir
# write_note_def
description:
  "Replace a note's entire content, or create the note if it does not exist. " <>
    "Saves, indexes for search, and syncs to Obsidian. Overwrites whatever the note held. " <>
    "To add text without touching existing content use append_to_note. To change one " <>
    "passage use patch_note, or one heading's section use update_section. To create a " <>
    "note with no risk of overwriting an existing one use create_note.",

# patch_note_def
description:
  "Find exact text in an existing note and replace it. Replaces the first occurrence " <>
    "by default; set occurrence to -1 for all, or 1 for the second. Fails if the text " <>
    "is not found. To replace everything under a heading use update_section. To add " <>
    "text use append_to_note. To rewrite the whole note use write_note.",

# update_section_def
description:
  "Replace everything under one heading in an existing note, up to the next heading " <>
    "of the same or higher level. The heading line itself is kept. Fails if the heading " <>
    "is not found. To change a specific passage use patch_note. To add text at the end " <>
    "use append_to_note.",

# append_to_note_def
description:
  "Add text to the end of a note, creating the note if it does not exist. Never " <>
    "removes or changes existing content. Use for logs, journals and running lists. " <>
    "To change existing text use patch_note. To replace the whole note use write_note.",

# delete_note_def
description:
  "Permanently delete one note by path; the deletion syncs to all connected Obsidian " <>
    "devices. Deleting a path that holds no note succeeds and reports deleted: false. " <>
    "To remove a whole folder use delete_folder. To move a note instead use rename_note.",

# list_folder_def
description:
  "List the notes and attachments directly inside one folder (not subfolders). Pass " <>
    "an empty string for the vault root. To see every folder in the vault with note " <>
    "counts use list_folders. To find notes by content use search_notes.",

# list_vaults_def
description:
  "List your vaults with their IDs, names and slugs. Call this first when you own " <>
    "more than one vault: every other tool needs a vault_id (a name or ID from this " <>
    "list) to know which vault to act on.",

# rename_note_def
description:
  "Rename or move one note to a new path; links pointing at it are rewritten and the " <>
    "change syncs to all Obsidian devices. Fails if a note already exists at the new " <>
    "path. To move a whole folder use rename_folder. To move an image or PDF use " <>
    "move_attachment.",

# rename_folder_def
description:
  "Rename or move a folder, including every note, attachment and subfolder inside it. " <>
    "All affected notes are reindexed and synced. To move a single note use rename_note.",
```

- [ ] **Step 4: Run tests, regenerate the snapshot, lint locally**

```bash
mise exec -- mix test test/engram/mcp/tools_descriptions_test.exs test/engram/mcp/tools_annotations_test.exs test/engram_web/controllers/mcp_controller_test.exs
mise exec -- mix engram.mcp.tools_json
npx -y mcp-tdqs@0.2.0 lint --file mcp-tools.json --server-name engram --fail-on warning
```

Expected: all PASS, lint exit 0.

- [ ] **Step 5: Commit, push, open PR 2, compare scores**

```bash
git add lib/engram/mcp/tools.ex mcp-tools.json test/engram/mcp/tools_descriptions_test.exs
git commit -m "feat(mcp): tool descriptions say when to use each sibling"
mise exec -- git push -u origin feat/mcp-tool-descriptions
gh pr create --title "feat(mcp): tool descriptions say when to use each sibling" --body "Phase 2 of the MCP tool surface spec. Refs #1767"
```

The `mcp-tdqs-score` run triggered by the push must show a higher overall score than the baseline, and no tool's Usage Guidelines may drop. If a tool drops, rewrite its description, do not merge.

---

# Phase 3: Consolidation, Option A: 21 to 17 tools (PR 3, branch `feat/mcp-tool-consolidation`)

Final listed roster (17): `list_vaults`, `search_notes`, `list_tags`, `list_folder`, `create_folder`, `suggest_folder`, `get_notes`, `create_note`, `write_note`, `append_to_note`, `edit_note`, `rename_note`, `rename_folder`, `delete_note`, `delete_folder`, `move_attachment`, `get_attachment_upload_target`.

Hidden aliases (callable, not listed): `get_note`, `list_folders`, `patch_note`, `update_section`, `set_vault`.

### Task 3.1: Split the roster into listed tools and hidden aliases

**Files:**
- Modify: `lib/engram/mcp/tools.ex` (`list/0`, `get/1`, add `aliases/0`, add `all_callable/0`)
- Modify: `lib/engram_web/controllers/mcp_controller.ex:133` (`@tool_atoms`)
- Test: `test/engram/mcp/tools_aliases_test.exs` (new)

**Interfaces:**
- Produces:
  - `Engram.MCP.Tools.aliases() :: [tool_def()]`, the retired tools, each keeping its old handler and schemas, plus `deprecated_for: String.t()`.
  - `Engram.MCP.Tools.all_callable() :: [tool_def()]` = `list() ++ aliases()`.
  - `Engram.MCP.Tools.get/1` resolves listed tools first, then aliases.

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/mcp/tools_aliases_test.exs
defmodule Engram.MCP.ToolsAliasesTest do
  use ExUnit.Case, async: true

  alias Engram.MCP.Tools

  @retired %{
    "get_note" => "get_notes",
    "list_folders" => "list_folder",
    "patch_note" => "edit_note",
    "update_section" => "edit_note",
    "set_vault" => "list_vaults"
  }

  test "retired tools are not listed" do
    listed = Enum.map(Tools.list(), & &1.name)
    for {old, _} <- @retired, do: refute(old in listed, "#{old} is still listed")
    assert length(listed) == 17
  end

  test "retired tools still resolve through get/1 and name their replacement" do
    for {old, new} <- @retired do
      assert {:ok, tool} = Tools.get(old)
      assert tool.deprecated_for == new
    end
  end

  test "an unknown name still does not resolve" do
    assert Tools.get("no_such_tool") == :error
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/engram/mcp/tools_aliases_test.exs`
Expected: FAIL (retired names still listed; count 21).

- [ ] **Step 3: Implement**

In `lib/engram/mcp/tools.ex`:

```elixir
  # Retired tool names that stay CALLABLE (clients cache tools/list and our own
  # skills call them by name) but are no longer listed. Each keeps its old
  # handler and schemas, so an old call behaves exactly as before. Remove an
  # alias only after 60 days AND 30 consecutive days of zero calls:
  #   sum by (tool) (increase(engram_prom_ex_mcp_tool_total{env="prod",tool="<old>"}[30d]))
  @retired %{
    "get_note" => "get_notes",
    "list_folders" => "list_folder",
    "patch_note" => "edit_note",
    "update_section" => "edit_note",
    "set_vault" => "list_vaults"
  }

  @spec aliases() :: [tool_def()]
  def aliases do
    [get_note_def(), list_folders_def(), patch_note_def(), update_section_def(), set_vault_def()]
    |> Enum.map(&(&1 |> with_vault_id() |> with_annotations()))
    |> Enum.map(&Map.put(&1, :deprecated_for, Map.fetch!(@retired, &1.name)))
  end

  @spec all_callable() :: [tool_def()]
  def all_callable, do: list() ++ aliases()

  @spec get(String.t()) :: {:ok, tool_def()} | :error
  def get(name) do
    case Enum.find(all_callable(), &(&1.name == name)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end
```

Remove `set_vault_def()`, `list_folders_def()`, `get_note_def()`, `patch_note_def()` and `update_section_def()` from the list in `list/0`, and add `edit_note_def()` (defined in Task 3.3; until then leave a compile-time stub is NOT allowed, so do Task 3.3's `edit_note_def/0` in this same commit if the count test needs 17, or temporarily assert 16 and bump to 17 in Task 3.3's commit). Keep all five retired entries in `@annotations`.

In `lib/engram_web/controllers/mcp_controller.ex:133`, so an alias call is tagged with its own name instead of `:unknown`:

```elixir
  @tool_atoms Map.new(Tools.all_callable(), &{&1.name, String.to_atom(&1.name)})
```

`@vault_exempt` needs no change: `Tools.vault_scoping_exempt/0` still returns `~w(list_vaults set_vault)`, and `dispatch_tool/4` matches on the resolved tool's name.

- [ ] **Step 4: Run** `mise exec -- mix test test/engram/mcp/tools_aliases_test.exs`. Expected: PASS (with the 16/17 note above).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/mcp/tools.ex lib/engram_web/controllers/mcp_controller.ex test/engram/mcp/tools_aliases_test.exs
git commit -m "feat(mcp): retire five tool names behind callable aliases"
```

### Task 3.2: Deprecation hint on alias calls, identical structured output

**Files:**
- Modify: `lib/engram_web/controllers/mcp_controller.ex:770-790` (`run_tool_handler/4`)
- Test: `test/engram_web/controllers/mcp_tool_aliases_test.exs` (new)

**Interfaces:**
- Consumes: `tool.deprecated_for` (Task 3.1).

The spec asks for both "byte-identical output" and "a deprecation nudge in the text". Resolution used here: `structuredContent` is byte-identical to the pre-change tool; the text `content` gets one appended line. Programmatic clients read `structuredContent`; the model reads the text and learns the new name.

- [ ] **Step 1: Write the failing test** (reuse the `setup` and `jsonrpc/3` helper from `test/engram_web/controllers/mcp_controller_test.exs:8-50`; copy them into this file)

```elixir
  test "get_note alias: same structuredContent, deprecation line, own telemetry tag", ctx do
    %{conn: conn, user: user, vault: vault} = ctx
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "# A\n\nhi", "mtime" => 1.0})

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :mcp, :tool, :stop]])

    resp =
      conn
      |> jsonrpc("tools/call", %{"name" => "get_note", "arguments" => %{"source_path" => "A.md"}})
      |> json_response(200)

    result = resp["result"]
    assert result["structuredContent"]["path"] == "A.md"
    assert result["structuredContent"]["content"] =~ "hi"
    [%{"text" => text}] = result["content"]
    assert text =~ "get_note is deprecated; use get_notes"

    assert_receive {[:engram, :mcp, :tool, :stop], ^ref, _, %{tool: :get_note, status: :ok}}
  end

  test "set_vault alias still validates a vault by name", ctx do
    %{conn: conn, vault: vault} = ctx

    resp =
      conn
      |> jsonrpc("tools/call", %{"name" => "set_vault", "arguments" => %{"vault_id" => vault.name}})
      |> json_response(200)

    assert resp["result"]["structuredContent"]["vault"]["id"] == to_string(vault.id)
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/engram_web/controllers/mcp_tool_aliases_test.exs`
Expected: FAIL on the `deprecated` text assertion.

- [ ] **Step 3: Implement** in `run_tool_handler/4`, wrap the success branches:

```elixir
  @doc false
  def run_tool_handler(tool, user, vault, args) do
    case tool.handler.(user, vault, args) do
      {:ok, text} ->
        text = deprecation_note(tool, text)
        {{:ok, text_result(text)}, :ok, byte_size_safe(text)}

      {:ok, text, structured} when is_map(structured) ->
        text = deprecation_note(tool, text)
        result = Map.put(text_result(text), "structuredContent", structured)
        {{:ok, result}, :ok, byte_size_safe(text)}

      {:error, msg} ->
        {error_result(msg), :error, byte_size_safe(msg)}
    end
  catch
    # ... unchanged
  end

  defp deprecation_note(%{deprecated_for: new, name: old}, text) do
    require Logger
    Logger.info("mcp deprecated tool called", tool: old, replacement: new)
    text <> "\n\n(#{old} is deprecated; use #{new}.)"
  end

  defp deprecation_note(_tool, text), do: text
```

Keep the existing comments in `run_tool_handler/4`; only add the two `deprecation_note/2` calls.

- [ ] **Step 4: Run** the new test plus `test/engram_web/controllers/mcp_controller_test.exs` and `test/engram/mcp/handlers_test.exs`. Expected: PASS. Existing handler tests call `Handlers.handle("get_note", ...)` directly and are unaffected.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/controllers/mcp_controller.ex test/engram_web/controllers/mcp_tool_aliases_test.exs
git commit -m "feat(mcp): deprecated tool calls work and name their replacement"
```

### Task 3.3: `edit_note` (replace_text | replace_section)

**Files:**
- Modify: `lib/engram/mcp/tools.ex` (add `edit_note_def/0`, `@annotations` entry `"edit_note" => {"Edit Note", false, true, false}`)
- Modify: `lib/engram/mcp/handlers.ex` (extract the bodies of `handle("patch_note", ...)` at :379 and `handle("update_section", ...)` at :412 into `defp patch_text/5` and `defp replace_section/5`; add `handle("edit_note", ...)`)
- Test: `test/engram/mcp/handlers_edit_note_test.exs` (new)

**Interfaces:**
- Produces: tool `edit_note`, input `path` (required), `mode` (required, `"replace_text" | "replace_section"`), `find`, `replace`, `occurrence`, `expected_replacements` (replace_text), `heading`, `content`, `level` (replace_section). Hidden param aliases `old_text` -> `find`, `new_text` -> `replace`. Output `{path, mode, replacements, heading}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/mcp/handlers_edit_note_test.exs
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
             Handlers.handle("edit_note", u, v, %{"path" => "N.md", "mode" => "replace_text", "find" => "a", "replace" => "b"})

    assert body(u, v) =~ "## Todo\n\nb\na"
  end

  test "replace_text refuses when expected_replacements does not match, and writes nothing", %{user: u, vault: v} do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md", "mode" => "replace_text", "find" => "a", "replace" => "b",
               "occurrence" => -1, "expected_replacements" => 1
             })

    assert msg =~ "expected 1 replacement(s), found 2"
    assert body(u, v) == before
  end

  test "replace_text accepts old_text/new_text aliases", %{user: u, vault: v} do
    assert {:ok, _, %{"replacements" => 1}} =
             Handlers.handle("edit_note", u, v, %{"path" => "N.md", "mode" => "replace_text", "old_text" => "x", "new_text" => "y"})
  end

  test "replace_section replaces under the heading only", %{user: u, vault: v} do
    assert {:ok, _, %{"heading" => "Todo", "mode" => "replace_section"}} =
             Handlers.handle("edit_note", u, v, %{"path" => "N.md", "mode" => "replace_section", "heading" => "Todo", "content" => "z"})

    assert body(u, v) =~ "## Todo\nz\n## Done"
  end

  # Review Focus 1
  test "a parameter from the other mode is a fixable error, not a partial edit", %{user: u, vault: v} do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{"path" => "N.md", "mode" => "replace_text", "find" => "a", "replace" => "b", "heading" => "Todo"})

    assert msg =~ "heading is only valid with mode replace_section"
    assert body(u, v) == before
  end

  test "missing mode-required params are named", %{user: u, vault: v} do
    assert {:error, msg} = Handlers.handle("edit_note", u, v, %{"path" => "N.md", "mode" => "replace_section", "content" => "z"})
    assert msg =~ "heading is required for mode replace_section"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/engram/mcp/handlers_edit_note_test.exs`
Expected: FAIL, `no function clause matching in Engram.MCP.Handlers.handle/4` for `"edit_note"`.

- [ ] **Step 3: Implement the handler**

Extract the existing `patch_note` body into `defp patch_text(user, vault, path, %{find, replace, occurrence}, expected)` and the `update_section` body into `defp replace_section(user, vault, path, heading, content, level)` without changing their logic, and make `handle("patch_note", ...)` / `handle("update_section", ...)` call them (so the aliases keep byte-identical behavior). `patch_text/5` checks `expected` right after `do_replace/4` computes `count`:

```elixir
          cond do
            count == 0 -> {:error, "Occurrence #{occurrence} not found in #{path}"}
            is_integer(expected) and expected != count ->
              {:error, "expected #{expected} replacement(s), found #{count} in #{path}; nothing was changed"}
            true -> patch_upsert(user, vault, path, note, new_content, count)
          end
```

Then:

```elixir
  @text_params ~w(find replace occurrence expected_replacements old_text new_text)
  @section_params ~w(heading content level)

  def handle("edit_note", user, vault, %{"mode" => mode} = args) do
    path = args["path"] || ""

    with :ok <- reject_other_mode(args, mode),
         {:ok, result} <- run_edit(user, vault, path, mode, args) do
      result
    end
  end

  defp reject_other_mode(args, "replace_text"), do: reject_params(args, @section_params, "replace_section")
  defp reject_other_mode(args, "replace_section"), do: reject_params(args, @text_params, "replace_text")
  defp reject_other_mode(_args, mode), do: {:error, "mode must be replace_text or replace_section, got #{inspect(mode)}"}

  defp reject_params(args, params, owner) do
    case Enum.find(params, &Map.has_key?(args, &1)) do
      nil -> :ok
      p -> {:error, "#{p} is only valid with mode #{owner}"}
    end
  end

  defp run_edit(user, vault, path, "replace_text", args) do
    find = args["find"] || args["old_text"]
    replace = args["replace"] || args["new_text"]

    cond do
      not is_binary(find) -> {:error, "find is required for mode replace_text"}
      not is_binary(replace) -> {:error, "replace is required for mode replace_text"}
      true ->
        user
        |> patch_text(vault, path, %{find: find, replace: replace, occurrence: args["occurrence"] || 0}, args["expected_replacements"])
        |> tag_mode("replace_text", %{"heading" => nil})
        |> then(&{:ok, &1})
    end
  end

  defp run_edit(user, vault, path, "replace_section", args) do
    cond do
      not is_binary(args["heading"]) -> {:error, "heading is required for mode replace_section"}
      not is_binary(args["content"]) -> {:error, "content is required for mode replace_section"}
      true ->
        user
        |> replace_section(vault, path, args["heading"], args["content"], args["level"] || 2)
        |> tag_mode("replace_section", %{"replacements" => nil})
        |> then(&{:ok, &1})
    end
  end

  defp tag_mode({:ok, text, structured}, mode, blanks),
    do: {:ok, text, structured |> Map.merge(blanks) |> Map.put("mode", mode)}

  defp tag_mode(other, _mode, _blanks), do: other
```

`edit_note_def/0` in `tools.ex`:

```elixir
  defp edit_note_def do
    %{
      name: "edit_note",
      description:
        "Change part of an existing note. mode replace_text finds exact text and replaces " <>
          "it (first occurrence by default); mode replace_section replaces everything under " <>
          "one heading. Fails without writing if the text or heading is not found, or if " <>
          "expected_replacements does not match. To add text use append_to_note. To " <>
          "rewrite the whole note use write_note.",
      inputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path of the note, e.g. \"Projects/Alpha.md\""},
          "mode" => %{"type" => "string", "enum" => ["replace_text", "replace_section"], "description" => "replace_text or replace_section"},
          "find" => %{"type" => "string", "description" => "replace_text only: exact text to find"},
          "replace" => %{"type" => "string", "description" => "replace_text only: text to put in its place"},
          "occurrence" => %{"type" => "integer", "description" => "replace_text only: 0 = first (default), 1 = second, -1 = all", "default" => 0},
          "expected_replacements" => %{"type" => "integer", "description" => "replace_text only: fail without writing unless exactly this many are replaced"},
          "heading" => %{"type" => "string", "description" => "replace_section only: heading text without the # prefix"},
          "content" => %{"type" => "string", "description" => "replace_section only: new content for under the heading"},
          "level" => %{"type" => "integer", "description" => "replace_section only: heading level 1-6 (default 2)", "default" => 2}
        },
        "required" => ["path", "mode"]
      },
      outputSchema: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "mode" => %{"type" => "string"},
          "replacements" => %{"type" => ["integer", "null"], "description" => "replace_text: occurrences replaced"},
          "heading" => %{"type" => ["string", "null"], "description" => "replace_section: heading updated"}
        },
        "required" => ["path", "mode"]
      },
      handler: &Handlers.handle("edit_note", &1, &2, &3)
    }
  end
```

- [ ] **Step 4: Run** the new test file plus `test/engram/mcp/handlers_test.exs`, `test/engram/mcp/handlers_write_contract_test.exs`, `test/engram/mcp/tools_annotations_test.exs` (update its `@destructive` list: add `edit_note`; `patch_note`/`update_section` remain destructive as aliases). Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/mcp/tools.ex lib/engram/mcp/handlers.ex test/engram/mcp/handlers_edit_note_test.exs test/engram/mcp/tools_annotations_test.exs
git commit -m "feat(mcp): edit_note replaces patch_note and update_section"
```

### Task 3.4: `append_to_note(position: end | start)`

**Files:**
- Modify: `lib/engram/mcp/tools.ex` (`append_to_note_def`, add `position` property)
- Modify: `lib/engram/mcp/handlers.ex:342` (`handle("append_to_note", ...)`)
- Test: `test/engram/mcp/handlers_append_position_test.exs` (new)

- [ ] **Step 1: Write the failing tests** (Review Focus 2)

```elixir
defmodule Engram.MCP.HandlersAppendPositionTest do
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put!(u, v, path, content),
    do: {:ok, _} = Notes.upsert_note(u, v, %{"path" => path, "content" => content, "mtime" => 1.0})

  defp body(u, v, path) do
    {:ok, note} = Notes.get_note(u, v, path)
    {:ok, c} = Notes.authoritative_content(u, note)
    c
  end

  test "start inserts after the frontmatter fence, frontmatter untouched", %{user: u, vault: v} do
    put!(u, v, "F.md", "---\ntags: [a]\n---\n# F\n\nold\n")
    assert {:ok, _, _} = Handlers.handle("append_to_note", u, v, %{"path" => "F.md", "text" => "new", "position" => "start"})
    assert body(u, v, "F.md") =~ ~r/\A---\ntags: \[a\]\n---\nnew\n# F/
  end

  test "start with no frontmatter goes to the very top", %{user: u, vault: v} do
    put!(u, v, "P.md", "# P\n\nold\n")
    assert {:ok, _, _} = Handlers.handle("append_to_note", u, v, %{"path" => "P.md", "text" => "new", "position" => "start"})
    assert body(u, v, "P.md") =~ ~r/\Anew\n# P/
  end

  test "default position is still end", %{user: u, vault: v} do
    put!(u, v, "E.md", "# E\n\nold\n")
    assert {:ok, _, _} = Handlers.handle("append_to_note", u, v, %{"path" => "E.md", "text" => "new"})
    assert body(u, v, "E.md") =~ ~r/old\nnew\z/
  end

  test "an unknown position is a fixable error", %{user: u, vault: v} do
    put!(u, v, "X.md", "x")
    assert {:error, msg} = Handlers.handle("append_to_note", u, v, %{"path" => "X.md", "text" => "t", "position" => "middle"})
    assert msg =~ "position must be end or start"
  end
end
```

- [ ] **Step 2: Run** `mise exec -- mix test test/engram/mcp/handlers_append_position_test.exs`. Expected: FAIL on the `start` and error cases.

- [ ] **Step 3: Implement.** Add to the schema: `"position" => %{"type" => "string", "enum" => ["end", "start"], "default" => "end", "description" => "end (default) appends; start inserts at the top, after any frontmatter"}`. In the handler, validate `position` first (`{:error, "position must be end or start"}`), and pass the rebuild function by position:

```elixir
  defp place_text(content, text, "end"), do: String.trim_trailing(content, "\n") <> "\n" <> text

  defp place_text(content, text, "start") do
    case Engram.Notes.Frontmatter.split(content) do
      {nil, body} -> text <> "\n" <> body
      {frontmatter, body} -> String.replace_suffix(content, body, "") <> text <> "\n" <> body
    end
  end
```

Confirm what `Frontmatter.split/1` returns for the first element (raw YAML vs the fenced block) by reading `lib/engram/notes/frontmatter.ex:15-60` before writing the `start` clause; the test pins the byte result either way. The not-found branch (create) ignores `position`. Update the description: add "Set position to start to insert at the top (after any frontmatter) instead."

- [ ] **Step 4: Run** the new tests and `test/engram/mcp/handlers_test.exs`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/mcp/tools.ex lib/engram/mcp/handlers.ex test/engram/mcp/handlers_append_position_test.exs
git commit -m "feat(mcp): append_to_note can insert at the top"
```

### Task 3.5: `list_folder(recursive)` absorbs `list_folders`

**Files:**
- Modify: `lib/engram/mcp/tools.ex` (`list_folder_def`: `folder` no longer required, default `""`; add `recursive` boolean; add `folders` to outputSchema)
- Modify: `lib/engram/mcp/handlers.ex:146` (`handle("list_folder", ...)`)
- Test: add to `test/engram/mcp/handlers_test.exs`, `describe "list_folder attachment visibility"` block (line 278)

- [ ] **Step 1: Write the failing tests**

```elixir
    test "reports direct subfolders; recursive reports every descendant with counts", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      for p <- ["A/a.md", "A/B/b.md", "A/B/C/c.md", "Z/z.md"],
          do: {:ok, _} = Notes.upsert_note(user, vault, %{"path" => p, "content" => "x", "mtime" => 1.0})

      {:ok, _, direct} = Handlers.handle("list_folder", user, vault, %{"folder" => "A"})
      assert Enum.map(direct["folders"], & &1["folder"]) == ["A/B"]

      {:ok, _, all} = Handlers.handle("list_folder", user, vault, %{"folder" => "", "recursive" => true})
      assert Enum.map(all["folders"], & &1["folder"]) |> Enum.sort() == ["A", "A/B", "A/B/C", "Z"]
      assert Enum.find(all["folders"], &(&1["folder"] == "A/B"))["count"] == 1
    end
```

- [ ] **Step 2: Run to verify it fails** (`folders` key missing).

- [ ] **Step 3: Implement** in the handler: after listing notes/attachments, derive folders from `Notes.list_folders_with_counts/2` (already used by the `list_folders` handler at :121) and filter in BEAM:

```elixir
  defp subfolders(user, vault, folder, recursive?) do
    {:ok, folders} = Notes.list_folders_with_counts(user, vault)
    prefix = if folder == "", do: "", else: folder <> "/"

    folders
    |> Enum.map(&%{"folder" => &1.folder || "", "count" => &1.count})
    |> Enum.filter(fn %{"folder" => f} ->
      f != "" and f != folder and String.starts_with?(f, prefix) and
        (recursive? or not String.contains?(String.replace_prefix(f, prefix, ""), "/"))
    end)
  end
```

Put the result under `"folders"` in the structured output (and a `Subfolders:` section in the text). Folders that hold only subfolders and no notes appear only if `list_folders_with_counts/2` returns them today; do not change that function.

- [ ] **Step 4: Run** `test/engram/mcp/handlers_test.exs`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/mcp/tools.ex lib/engram/mcp/handlers.ex test/engram/mcp/handlers_test.exs
git commit -m "feat(mcp): list_folder lists subfolders, recursively on request"
```

### Task 3.6: Descriptions that reference retired names, snapshot, roster test

**Files:**
- Modify: `lib/engram/mcp/tools.ex` (every listed description from Phase 2 that says `patch_note`/`update_section`/`list_folders`/`get_note` now says `edit_note`/`list_folder`/`get_notes`; `get_notes` description adds "Also reads a single note: pass one path."; `create_note` error text in `handlers.ex:294-302` says `get_notes`)
- Modify: `test/engram/mcp/tools_descriptions_test.exs` (`@siblings` to the new names)
- Modify: `test/engram_web/controllers/mcp_controller_test.exs:80-107` (`"tools/list returns 21 tools"` becomes 17; replace the asserts for `set_vault`, `get_note`, `patch_note`, `update_section` with `refute ... in names` and add `assert "edit_note" in names`). This replaces an assertion of intentionally removed behavior; say so in the commit body.
- Modify: `mcp-tools.json` (regenerate)

- [ ] **Step 1:** Update `@siblings` in the descriptions test first and run it: FAIL.
- [ ] **Step 2:** Update the descriptions; run the descriptions test, the controller test and the aliases test: PASS.
- [ ] **Step 3:** `mise exec -- mix engram.mcp.tools_json && npx -y mcp-tdqs@0.2.0 lint --file mcp-tools.json --server-name engram --fail-on warning` : exit 0.
- [ ] **Step 4: Commit**

```bash
git add lib/engram/mcp/tools.ex lib/engram/mcp/handlers.ex test/ mcp-tools.json
git commit -m "feat(mcp): 17-tool roster, descriptions point at the new names

tools/list count test changed from 21 to 17 because four names are
intentionally retired to aliases (still callable, see tools_aliases_test)."
```

### Task 3.7: Migrate our own callers

**Files:**
- Modify: `e2e/tests/api_only/test_32_vault_api_key_isolation.py:237,252,306` (`mcp_call("get_note", {"source_path": P})` becomes `mcp_call("get_notes", {"paths": [P]})` and the response assertions read `structuredContent.notes[0]`)
- Modify: `e2e/tests/test_83_cross_interface_orchestration.py:51` (same)
- Modify: `e2e/tests/api_only/test_75_free_mcp_search_cap.py:144` (`list_folders` becomes `list_folder` with `{"folder": "", "recursive": True}` and reads `folders`)
- Add: `e2e/tests/api_only/test_96_mcp_retired_aliases.py`, one test per alias proving an old-name call still succeeds (pins Review Focus 5 end to end)
- Outside this repo (separate commits, no PR needed for `~/.claude`):
  - `~/.claude/skills/work-log/SKILL.md:30,91,108`: drop the `set_vault` calls (pass `vault_id` on each call instead); line 30 `list_folders` becomes `list_folder(folder="", recursive=true)`
  - `~/.claude/skills/engram*/` references and evals that mention `set_vault`, `get_note`, `patch_note`, `update_section`, `list_folders` (grep list: `engram/references/{daily,search,read,update,browse}.md`, `engram-browse/SKILL.md`, `engram-search/SKILL.md`, `engram-update/SKILL.md`, and the two `evals/evals.json`)
  - workspace `CLAUDE.md:74` ("via the engram MCP (`set_vault` ... then `set_vault()` to reset)" becomes "pass `vault_id` on each call")
  - engram-skill repo: clone `engram-app/engram-skill` as a sibling and grep for the five names; migrate if present
  - marketing docs: `grep -rn "patch_note\|update_section\|get_note\b\|list_folders\|set_vault" src/content` in engram-marketing; update tool lists

- [ ] **Step 1:** Write `test_96_mcp_retired_aliases.py` (calls each retired name through `api.mcp_call`, asserts HTTP 200 and no `isError`), run it against the local CI stack per `docs/e2e-testing.md`: PASS (aliases landed in 3.1-3.2).
- [ ] **Step 2:** Migrate the three e2e files; run them: PASS.
- [ ] **Step 3:** Commit the e2e changes; open PR 3.

```bash
git add e2e/
git commit -m "test(e2e): call the consolidated MCP tools; pin retired aliases"
mise exec -- git push -u origin feat/mcp-tool-consolidation
gh pr create --title "feat(mcp): consolidate to 17 tools (edit_note, get_notes, list_folder)" --body "Phase 3 of the MCP tool surface spec. Retired names stay callable as aliases for 60+ days. Refs #1767"
```

- [ ] **Step 4:** After PR 3 merges and deploys, migrate the out-of-repo callers above and verify with one real work-log append.

---

# Phase 4: Recency and backlinks as parameters (PR 4, branch `feat/mcp-recent-backlinks`)

### Task 4.1: `search_notes` with no query lists recently updated notes

**Files:**
- Modify: `lib/engram/notes.ex` (add `list_recent_notes/3` next to `list_notes_in_folder/3` at :5281)
- Modify: `lib/engram/mcp/tools.ex` (`search_notes_def`: remove `"query"` from `required`; description gains "Omit query to list the most recently updated notes instead.")
- Modify: `lib/engram/mcp/handlers.ex:84-101` (both `search_notes` clauses)
- Test: `test/engram/mcp/handlers_recent_test.exs` (new), `test/engram/notes_recent_test.exs` (new)

**Interfaces:**
- Produces: `Engram.Notes.list_recent_notes(user, vault, limit) :: {:ok, [Note.t()]}`, live `kind == "note"` rows, newest `updated_at` first, metadata only (no content), decrypted.

Deviation from the spec, deliberate: no `sort` parameter. "No query" already means "recent", and a `sort: updated` combined with a query has no ordering signal to use (search hits carry no `updated_at`). One fewer parameter scores better on TDQS Parameter Semantics. Also deliberate: the listing is NOT filtered by the Free index cap, same as `list_folder`; the cap governs search indexing, and hiding a Free user's newest notes from a "what changed" list would hide exactly the notes they just wrote.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram/notes_recent_test.exs
defmodule Engram.NotesRecentTest do
  use Engram.DataCase, async: true
  alias Engram.Notes

  test "newest updated first, limited, notes only, own vault only" do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    other = insert(:vault, user: user)

    for {p, t} <- [{"old.md", 1.0}, {"mid.md", 2.0}, {"new.md", 3.0}] do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => p, "content" => "x", "mtime" => t})
      Process.sleep(2)
    end

    {:ok, _} = Notes.upsert_note(user, other, %{"path" => "elsewhere.md", "content" => "x", "mtime" => 9.0})

    {:ok, notes} = Notes.list_recent_notes(user, vault, 2)
    assert Enum.map(notes, & &1.path) == ["new.md", "mid.md"]
  end
end
```

```elixir
# test/engram/mcp/handlers_recent_test.exs
defmodule Engram.MCP.HandlersRecentTest do
  use Engram.DataCase, async: true
  alias Engram.MCP.Handlers

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    {:ok, _} = Engram.Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "# R\n\nx", "mtime" => 1.0})
    %{user: user, vault: vault}
  end

  # Review Focus 3: absent, empty and blank all mean "recent", with no search call
  for q <- [:absent, "", "   "] do
    test "query #{inspect(q)} lists recent notes without searching", %{user: u, vault: v} do
      args = if unquote(q) == :absent, do: %{}, else: %{"query" => unquote(q)}
      Mox.stub(Engram.MockEmbedder, :embed_texts, fn _ -> flunk("must not embed") end)

      assert {:ok, text, %{"results" => [hit]}} = Handlers.handle("search_notes", u, v, args)
      assert hit["source_path"] == "r.md"
      assert text =~ "Recently updated"
    end
  end
end
```

Check the embedder mock module name in `test/support/` (grep `defmock`) before writing the stub; use the real name.

- [ ] **Step 2: Run to verify both fail.**

- [ ] **Step 3: Implement.**

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

`lib/engram/mcp/handlers.ex`, first clauses of `search_notes`:

```elixir
  def handle("search_notes", user, {:cross_vault, vaults}, args) do
    if blank_query?(args) do
      limit = min(args["limit"] || 5, 20)

      vaults
      |> Enum.flat_map(fn v ->
        {:ok, notes} = Notes.list_recent_notes(user, v, limit)
        Enum.map(notes, &{&1, v})
      end)
      |> Enum.sort_by(fn {n, _} -> n.updated_at end, {:desc, DateTime})
      |> Enum.take(limit)
      |> render_recent(Map.new(vaults, &{to_string(&1.id), &1.name}))
    else
      # ... existing body unchanged
    end
  end

  def handle("search_notes", user, vault, args) do
    if blank_query?(args) do
      {:ok, notes} = Notes.list_recent_notes(user, vault, min(args["limit"] || 5, 20))
      render_recent(Enum.map(notes, &{&1, vault}), %{})
    else
      query = args["query"] || ""
      render_search(Search.search(user, vault, query, build_search_opts(args)), %{})
    end
  end

  defp blank_query?(args), do: String.trim(args["query"] || "") == ""

  defp render_recent(pairs, names) do
    text =
      if pairs == [] do
        "No notes yet."
      else
        ["Recently updated:" | Enum.map(pairs, fn {n, _} -> "- #{n.path} (#{n.updated_at})" end)]
        |> Enum.join("\n")
      end

    results =
      Enum.map(pairs, fn {n, v} ->
        %{
          "score" => 0,
          "title" => n.title,
          "source_path" => n.path,
          "tags" => n.tags || [],
          "text" => "",
          "vault_id" => if(names == %{}, do: nil, else: to_string(v.id)),
          "vault" => Map.get(names, to_string(v.id))
        }
      end)

    {:ok, text, %{"results" => results}}
  end
```

The result shape reuses the existing `search_notes` outputSchema (every field there is nullable except `score` and `text`), so no schema change. No `Search.search/4` call means no `ai_searches_per_day` charge.

- [ ] **Step 4: Run** both new test files plus `test/engram/mcp/handlers_search_mode_test.exs`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes.ex lib/engram/mcp/tools.ex lib/engram/mcp/handlers.ex test/engram/notes_recent_test.exs test/engram/mcp/handlers_recent_test.exs
git commit -m "feat(mcp): search_notes with no query lists recently updated notes"
```

### Task 4.2: `get_notes(include_backlinks: true)`

**Files:**
- Modify: `lib/engram/mcp/tools.ex` (`get_notes_def`: add `include_backlinks` boolean input; add `backlinks` array to the note item outputSchema: items `{source_path, source_title}` nullable strings)
- Modify: `lib/engram/mcp/handlers.ex:233` (`handle("get_notes", ...)`)
- Test: `test/engram/mcp/handlers_backlinks_test.exs` (new)

**Interfaces:**
- Consumes: `Engram.Links.backlinks_for_note(user, note_id) :: [%{source_note_id, source_path, source_title, alias, anchor, ...}]` (`lib/engram/links.ex:896`, capped at `Links.backlinks_limit/0`).

- [ ] **Step 1: Write the failing test** (Review Focus 4)

```elixir
defmodule Engram.MCP.HandlersBacklinksTest do
  use Engram.DataCase, async: false
  alias Engram.MCP.Handlers
  alias Engram.Notes

  test "found notes carry backlinks; a missing path carries none and does not fail the batch" do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Target.md", "content" => "# T", "mtime" => 1.0})
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Source.md", "content" => "see [[Target]]", "mtime" => 2.0})

    assert {:ok, _, %{"notes" => [found, missing]}} =
             Handlers.handle("get_notes", user, vault, %{"paths" => ["Target.md", "Nope.md"], "include_backlinks" => true})

    assert [%{"source_path" => "Source.md"}] = found["backlinks"]
    assert missing == %{"path" => "Nope.md", "found" => false}
  end

  test "without the flag the payload is unchanged" do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "a", "mtime" => 1.0})

    {:ok, _, %{"notes" => [n]}} = Handlers.handle("get_notes", user, vault, %{"paths" => ["A.md"]})
    refute Map.has_key?(n, "backlinks")
  end
end
```

Link extraction may be asynchronous (an Oban job or the link-extract fast path, see `lib/engram/links.ex:1-120`). If `backlinks_for_note/2` returns `[]` right after the upsert, call the synchronous extractor the existing link tests use (grep `test/engram/links*` for how they populate `note_links`) rather than sleeping.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** in the `true ->` branch of `handle("get_notes", ...)`:

```elixir
        with_backlinks? = args["include_backlinks"] == true

        notes =
          Enum.map(fetched, fn
            {_path, %{} = note} ->
              payload = Map.put(note_payload(note), "found", true)

              if with_backlinks?,
                do: Map.put(payload, "backlinks", backlinks_payload(user, note)),
                else: payload

            {path, nil} ->
              %{"path" => path, "found" => false}
          end)
```

```elixir
  defp backlinks_payload(user, note) do
    user
    |> Engram.Links.backlinks_for_note(note.id)
    |> Enum.map(&%{"source_path" => &1.source_path, "source_title" => &1.source_title})
  end
```

Add one text line per found note when the flag is set: `Backlinks: a.md, b.md` (or `Backlinks: none`). Update the description: "Pass include_backlinks: true to also get the notes that link to each one."

- [ ] **Step 4: Run** the new test and `test/engram/mcp/handlers_test.exs`. Expected: PASS.

- [ ] **Step 5: Regenerate the snapshot, lint, commit, open PR 4**

```bash
mise exec -- mix engram.mcp.tools_json
npx -y mcp-tdqs@0.2.0 lint --file mcp-tools.json --server-name engram --fail-on warning
git add lib/engram/mcp/tools.ex lib/engram/mcp/handlers.ex test/engram/mcp/handlers_backlinks_test.exs mcp-tools.json
git commit -m "feat(mcp): get_notes can include backlinks"
mise exec -- git push -u origin feat/mcp-recent-backlinks
gh pr create --title "feat(mcp): recent notes and backlinks through existing tools" --body "Phase 4 of the MCP tool surface spec. Refs #1767"
```

---

## Self-review notes

- Spec coverage: Phase 1 export (1.1, 1.2), lint gate (1.3), score job (1.4), baseline (1.5); Phase 2 (2.1); Phase 3 roster + aliases (3.1), nudge + telemetry (3.2), edit_note incl. expected_replacements and old_text/new_text (3.3), append position (3.4), list_folder recursive (3.5), descriptions + count (3.6), caller migration (3.7); Phase 4 recency (4.1), backlinks (4.2).
- Deliberate deviations from the spec, each stated in its task: no paths filter on the lint gate (the `lint` job fingerprint is the filter, and a paths-filtered required check would leave unrelated PRs pending); score workflow triggers on `push`, not `pull_request` (self-hosted fork guard); no `sort` parameter and no index-cap filter on the recent listing (Task 4.1); alias output is `structuredContent`-identical with a one-line text hint (Task 3.2).
- Human prerequisites: `ANTHROPIC_API_KEY` repo secret before Task 1.4 step 2; directory resubmission check before PR 3 ships.
