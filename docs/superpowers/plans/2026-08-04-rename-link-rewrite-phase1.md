# Rename/Move Link-Rewrite Propagation — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Issues:** engram#648, engram#1231 · **Depends on:** note_links graph (merged PR #1229, commit `0fb668be`)

## Goal

When a note or attachment is renamed/moved via REST or MCP, every `[[wikilink]]`/`![[embed]]` in referring notes is rewritten server-side to the new name as real Y-updates, so all clients converge without conflicting with Obsidian's own link updating (plugin-origin renames are untouched — Obsidian rewrites those itself).

## Architecture

A new `Engram.Links.Rewriter` finds referring notes via the `note_links` edge table (`target_basename_hmac`, rename-order-proof), re-locates occurrences in each source note's canonical Y-doc (checkpoint snapshot + `crdt_update_log` tail — the exact `bind/3` recipe already used by `Notes.maybe_merge_crdt/4` and `Workers.CheckpointNote`) using `Engram.Links.Parser` (extended with target byte offsets), and authors positional `Yex.Text.delete/insert` edits in one Y-transaction. The delta is persisted through the SAME path client updates use — `Engram.Notes.CrdtPersistence.update_v1/4` (encrypted tail-log append + `FanoutPacer` broadcast) roomless, or `Yex.Sync.SharedDoc.update_doc/2` when a live room exists (its `update_v1` hook then appends + broadcasts to observers). A new Oban worker `Engram.Workers.RewriteNoteLinks` (cursor chain, NO `unique:`) drives it asynchronously; `Notes.rename_note/4` and `Attachments.move_attachment/4` enqueue it fire-and-forget.

## Tech Stack

Elixir 1.17+ / Phoenix 1.8+, Ecto + Postgres (RLS tenant scoping), Oban, `y_ex` (yrs NIF — `Yex.Doc` / `Yex.Text` / `Yex.Doc.transaction`), PromEx, ExUnit + `Oban.Testing` + `Engram.Fixtures`.

## Global Constraints

- **TDD mandatory**: write the failing test, run it, confirm the exact failure, then implement. Never modify a test to make bad code pass.
- **Sequential gauntlet before push**: `mix format` → `mix credo --strict` → `mix dialyzer` → full `mix test --warnings-as-errors` — SEQUENTIALLY, never concurrently (concurrent dialyzer starves the DB pool → fake failures).
- **No version bumps**: release-please owns `mix.exs` version; do not touch it.
- **Oban job args carry ids + base64 HMACs only** — never plaintext path/title/content/tags/folder/old_path/name. `test/engram/workers/no_plaintext_args_test.exs` lints worker sources for banned keys; keep it green.
- **Tenant scoping**: internal-pipeline queries use `skip_tenant_check: true` WITH explicit `user_id`/`vault_id` filters (the `lib/engram/links.ex` moduledoc precedent); anything touching `crdt_update_log` runs inside `Repo.with_tenant/2`.
- **No `unique:` on cursor-chain workers** — a cursor worker re-enqueues its own successor mid-run, which collides with its own `executing` row and silently kills the chain (see `Engram.Workers.BackfillNoteLinks` moduledoc).
- **The server authors only mechanical, semantics-preserving transforms** — never content the user didn't write. State this in the Rewriter moduledoc.
- **Rewrite failures never fail or roll back the rename** — enqueue via `Engram.Notes.Enqueue.enqueue/2` (logs + telemetry on failure, returns normally); worker isolates per-source-note errors.
- **Never write content snapshots** — persist Y-update deltas only; the roomless append is followed by a `CheckpointNote` enqueue so materialization stays owned by the existing checkpoint path.
- **Suppression triggers** (`# credo:disable`, `@dialyzer :nowarn`, skipped tests, swallowed exceptions): STOP and state the underlying problem before adding any.
- **No schema changes in Phase 1** — `note_links`, `basename_hmac`, and all indexes shipped in PR #1229. No migrations.
- **Branch prefix**: use `feat/` (a `ci/` prefix gets NO CI on this repo).
- **NOT in Phase 1**: CRDT-origin (web) renames, `client_type` socket tagging, folder renames, plugin changes.

---

### Task 1 — Parser: target-segment byte offsets

The parser returns `position` (byte offset of the whole match) but not where the *target segment* sits. The rewriter must edit only the target (preserving `!`, `|alias`, `#anchor` verbatim), so extend every occurrence map with `target_start`/`target_len` — byte offsets into the (scrubbed) content of the **trimmed** target text. Edge-extraction behavior is unchanged: `Links.replace_links/4` builds rows from named fields and ignores extra keys.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/lib/engram/links/parser.ex`
- Test: `/home/open-claw/documents/code-projects/engram/test/engram/links/parser_test.exs`

**Interfaces**
- Consumes: existing `@link_re` scan with `return: :index` (already yields `{inner_start, inner_len}`).
- Produces: `Engram.Links.Parser.extract/1 :: String.t() -> [%{target: String.t(), alias: String.t() | nil, anchor: String.t() | nil, link_type: String.t(), position: non_neg_integer(), target_start: non_neg_integer(), target_len: non_neg_integer()}]` — invariant: `binary_part(scrubbed_content, target_start, target_len) == target`.

**Steps**

- [ ] Write the failing tests (append to `test/engram/links/parser_test.exs` inside the existing module):

```elixir
  describe "target offsets" do
    test "offsets span exactly the trimmed target" do
      content = "pre ![[ Folder/Note.md |shown]] post"
      [occ] = Parser.extract(content)
      assert occ.link_type == "embed"
      assert occ.target == "Folder/Note.md"
      assert binary_part(content, occ.target_start, occ.target_len) == "Folder/Note.md"
    end

    test "offsets stop before the anchor and alias" do
      content = "[[Note#Head|shown]]"
      [occ] = Parser.extract(content)
      assert binary_part(content, occ.target_start, occ.target_len) == "Note"
      assert occ.anchor == "Head"
      assert occ.alias == "shown"
    end

    test "offsets are byte offsets, correct after multibyte text" do
      content = "émoji 🎈 [[Café]]"
      [occ] = Parser.extract(content)
      assert binary_part(content, occ.target_start, occ.target_len) == "Café"
    end

    test "every occurrence in a multi-link line carries its own span" do
      content = "[[A]] and ![[B|x]] and [[C#h]]"
      spans =
        content
        |> Parser.extract()
        |> Enum.map(&binary_part(content, &1.target_start, &1.target_len))

      assert spans == ["A", "B", "C"]
    end
  end
```

- [ ] Run: `cd /home/open-claw/documents/code-projects/engram && mix test test/engram/links/parser_test.exs` — expect **KeyError** (`key :target_start not found`) on the four new tests.
- [ ] Implement in `lib/engram/links/parser.ex`. Replace the `flat_map` body of `do_extract/1` and add `target_span/2`:

```elixir
  defp do_extract(content) do
    excluded = exclusion_ranges(content)

    @link_re
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{start, _len}, {_, bang_len}, {inner_start, inner_len}] ->
      inner = binary_part(content, inner_start, inner_len)

      case parse_inner(inner) do
        nil ->
          []

        parsed ->
          {t_start, t_len} = target_span(inner, inner_start)

          [
            Map.merge(parsed, %{
              link_type: link_type(bang_len),
              position: start,
              target_start: t_start,
              target_len: t_len
            })
          ]
      end
    end)
    |> Enum.reject(fn %{position: pos} -> in_ranges?(pos, excluded) end)
  end

  # Byte span of the TRIMMED target within the original (scrubbed) content.
  # Mirrors parse_inner/1's split order: first `|` bounds the body, first `#`
  # in the body bounds the target. do_extract/1 runs on already-scrubbed
  # content, so clean/1's scrub inside parse_inner is an identity there and
  # `binary_part(content, target_start, target_len) == parsed.target` holds.
  defp target_span(inner, inner_start) do
    body =
      case :binary.match(inner, "|") do
        {i, _} -> binary_part(inner, 0, i)
        :nomatch -> inner
      end

    target_raw =
      case :binary.match(body, "#") do
        {i, _} -> binary_part(body, 0, i)
        :nomatch -> body
      end

    lead = byte_size(target_raw) - byte_size(String.trim_leading(target_raw))
    trimmed = String.trim(target_raw)
    {inner_start + lead, byte_size(trimmed)}
  end
```

- [ ] Run: `mix test test/engram/links/parser_test.exs` — all pass. If any PRE-EXISTING test asserts a full occurrence map with `==`, update it to include `target_start`/`target_len` (pattern-match assertions are unaffected). Do not weaken any assertion.
- [ ] Run: `mix test test/engram/links_test.exs test/engram/indexing_links_test.exs` — unchanged behavior for edge extraction (extra keys ignored by `replace_links/4`).
- [ ] Commit: `feat(links): parser exposes target-segment byte offsets`

---

### Task 2 — Links: `live_basename_count/3` + `pre_rename_winner?/6`

Two public helpers on `Engram.Links` the rewriter needs. `live_basename_count/3` drives the form rule (bare stays bare only if the new basename is unambiguous). `pre_rename_winner?/6` answers "would this occurrence's target have resolved to the renamed row at its OLD path?" — reconstructed from the CURRENT candidate set plus a synthetic candidate `{renamed_id, old_path}` (excluding the renamed row's post-rename position). This makes the rewrite order-independent w.r.t. the `RebindNoteLinks` jobs the same rename enqueues (those flip edge target ids, but never `target_basename_hmac`/target text).

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/lib/engram/links.ex`
- Test: `/home/open-claw/documents/code-projects/engram/test/engram/links_test.exs`

**Interfaces**
- Consumes (already in `links.ex`, private, reused as-is): `fetch_decrypted_candidates/4`, `route_resolution/3`, `resolve_from_candidates/3`, `basename_key/1`.
- Produces:
  - `Engram.Links.live_basename_count(user :: map(), vault :: map(), key :: String.t()) :: non_neg_integer()` — live notes + attachments whose `basename_hmac` matches `basename_key` result `key`.
  - `Engram.Links.pre_rename_winner?(user, vault, target :: String.t(), kind :: :note | :attachment, renamed_id :: binary(), old_path :: String.t()) :: boolean()`

**Steps**

- [ ] Write the failing tests (append to `test/engram/links_test.exs`; the file's existing `setup` provides `%{user: user, vault: vault}`):

```elixir
  describe "live_basename_count/3" do
    test "counts live notes and attachments sharing a basename key", %{user: user, vault: vault} do
      Engram.Fixtures.insert_note!(user, vault, %{path: "a/Dup.md"})
      Engram.Fixtures.insert_note!(user, vault, %{path: "b/Dup.md"})
      Engram.Fixtures.insert_attachment!(user, vault, %{path: "c/Dup.png"})

      assert Links.live_basename_count(user, vault, "dup") == 2
      assert Links.live_basename_count(user, vault, "dup.png") == 1
      assert Links.live_basename_count(user, vault, "ghost") == 0
    end
  end

  describe "pre_rename_winner?/6" do
    test "true when the renamed note at its old path wins the tiebreak", %{
      user: user,
      vault: vault
    } do
      _longer = Engram.Fixtures.insert_note!(user, vault, %{path: "deep/nested/Dup.md"})
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Renamed.md"})

      assert Links.pre_rename_winner?(user, vault, "Dup", :note, renamed.id, "Dup.md")
    end

    test "false when a shorter-path sibling won pre-rename", %{user: user, vault: vault} do
      _sibling = Engram.Fixtures.insert_note!(user, vault, %{path: "Dup.md"})
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Renamed.md"})

      refute Links.pre_rename_winner?(user, vault, "Dup", :note, renamed.id, "x/Dup.md")
    end

    test "false when the target basename differs from the old basename", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Renamed.md"})

      refute Links.pre_rename_winner?(user, vault, "Other", :note, renamed.id, "Dup.md")
    end

    test "path-qualified target must match the old path (case-insensitive)", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Renamed.md"})

      assert Links.pre_rename_winner?(user, vault, "sub/Dup", :note, renamed.id, "Sub/Dup.md")
      refute Links.pre_rename_winner?(user, vault, "other/Dup", :note, renamed.id, "Sub/Dup.md")
    end

    test "attachment kind: renamed attachment at old path wins for its extensioned target", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_attachment!(user, vault, %{path: "new/pic.png"})

      assert Links.pre_rename_winner?(user, vault, "pic.png", :attachment, renamed.id, "old/pic.png")
    end
  end
```

- [ ] Run: `mix test test/engram/links_test.exs` — expect **UndefinedFunctionError** for `Links.live_basename_count/3` and `Links.pre_rename_winner?/6`.
- [ ] Implement in `lib/engram/links.ex` (insert after `basename_hmac/2`):

```elixir
  @doc """
  Live (non-deleted) notes + attachments in `vault` whose `basename_hmac`
  matches `key` (a `basename_key/1` result). Drives the rename-rewrite form
  rule: a bare `[[basename]]` may stay bare only when the new basename is
  unambiguous (count == 1, the renamed row itself).
  """
  @spec live_basename_count(map(), map(), String.t()) :: non_neg_integer()
  def live_basename_count(user, vault, key) do
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    hmac = Crypto.hmac_field(filter_key, key)

    notes =
      Repo.one(
        from(n in Note,
          where:
            n.user_id == ^user.id and n.vault_id == ^vault.id and n.kind == "note" and
              n.basename_hmac == ^hmac and is_nil(n.deleted_at),
          select: count(n.id)
        ),
        skip_tenant_check: true
      )

    attachments =
      Repo.one(
        from(a in Attachment,
          where:
            a.user_id == ^user.id and a.vault_id == ^vault.id and
              a.basename_hmac == ^hmac and is_nil(a.deleted_at),
          select: count(a.id)
        ),
        skip_tenant_check: true
      )

    notes + attachments
  end

  @doc """
  Would `target` have resolved to the renamed row (`renamed_id`) at its OLD
  path, under `resolve_target/4`'s rules? Reconstructs the pre-rename
  candidate set: current live candidates for the target's basename hmac,
  minus the renamed row's post-rename position, plus a synthetic candidate
  `{renamed_id, old_path}`. Order-independent w.r.t. the RebindNoteLinks
  jobs a rename enqueues — those rewrite edge target ids but never the
  candidate tables this consults.
  """
  @spec pre_rename_winner?(map(), map(), String.t(), :note | :attachment, binary(), String.t()) ::
          boolean()
  def pre_rename_winner?(user, vault, target, kind, renamed_id, old_path) do
    key = basename_key(target)

    if key != basename_key(old_path) do
      false
    else
      {:ok, filter_key} = Crypto.dek_filter_key(user)
      hmac = Crypto.hmac_field(filter_key, key)

      notes =
        user
        |> fetch_decrypted_candidates(vault, hmac, :notes)
        |> Enum.reject(fn {id, _path} -> id == renamed_id end)

      attachments =
        user
        |> fetch_decrypted_candidates(vault, hmac, :attachments)
        |> Enum.reject(fn {id, _path} -> id == renamed_id end)

      {notes, attachments} =
        case kind do
          :note -> {[{renamed_id, old_path} | notes], attachments}
          :attachment -> {notes, [{renamed_id, old_path} | attachments]}
        end

      ext = target |> Path.basename() |> Path.extname() |> String.downcase()

      case route_resolution(
             ext,
             fn -> resolve_from_candidates(notes, target, :note) end,
             fn -> resolve_from_candidates(attachments, target, :attachment) end
           ) do
        {:note, ^renamed_id} -> true
        {:attachment, ^renamed_id} -> true
        _ -> false
      end
    end
  end
```

  Note: `fetch_decrypted_candidates/4` is called as `fetch_decrypted_candidates(user, vault, hmac, :notes)` — keep the existing arg order; the pipe above starts from `user`.
- [ ] Run: `mix test test/engram/links_test.exs` — all pass.
- [ ] Commit: `feat(links): pre-rename winner + live basename count helpers`

---

### Task 3 — Rewriter planning core (occurrence selection, form rule, splice)

Pure-ish core of `Engram.Links.Rewriter`: given the current full text, decide WHICH occurrences to rewrite and WHAT the replacement target text is. No CRDT, no persistence yet. The target spec is a plain map built once per rename: `%{kind, id, old_path, new_path, old_basename_hmac, collision?}`.

**Files**
- Create: `/home/open-claw/documents/code-projects/engram/lib/engram/links/rewriter.ex`
- Test: `/home/open-claw/documents/code-projects/engram/test/engram/links/rewriter_test.exs`

**Interfaces**
- Consumes: `Engram.Links.Parser.extract/1` (with Task 1 offsets), `Engram.Links.basename_key/1`, `Engram.Links.pre_rename_winner?/6` (Task 2).
- Produces:
  - `Engram.Links.Rewriter.plan_edits(user, vault, full_text :: String.t(), body :: String.t(), target :: map()) :: [%{rel_start: non_neg_integer(), len: non_neg_integer(), old: String.t(), new: String.t()}]` — `rel_start`/`len` are byte offsets **into `body`**.
  - `Engram.Links.Rewriter.splice(text :: String.t(), edits :: [map()]) :: String.t()` (`@doc false`; descending-offset string application, used by the legacy branch and the round-trip tests).

**Steps**

- [ ] Create `test/engram/links/rewriter_test.exs` with the semantics matrix:

```elixir
defmodule Engram.Links.RewriterTest do
  use Engram.DataCase, async: true

  alias Engram.Links
  alias Engram.Links.{Parser, Rewriter}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp note_target(renamed, old_path, new_path, collision?) do
    %{
      kind: :note,
      id: renamed.id,
      old_path: old_path,
      new_path: new_path,
      old_basename_hmac: nil,
      collision?: collision?
    }
  end

  describe "plan_edits/5 — semantics matrix" do
    test "bare / aliased / anchored / embed all rewrite only the target segment", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Fresh.md"})
      full = "a [[Old]] b ![[Old|shown]] c [[Old#H1|x]] d"

      edits = Rewriter.plan_edits(user, vault, full, full, note_target(renamed, "Old.md", "Fresh.md", false))

      assert length(edits) == 3
      assert Enum.all?(edits, &(&1.new == "Fresh"))
      assert Enum.all?(edits, &(binary_part(full, &1.rel_start, &1.len) == "Old"))

      assert Rewriter.splice(full, edits) ==
               "a [[Fresh]] b ![[Fresh|shown]] c [[Fresh#H1|x]] d"
    end

    test "code fences and inline code are skipped by construction", %{user: user, vault: vault} do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Fresh.md"})
      full = "[[Old]]\n```\n[[Old]]\n```\nand `[[Old]]` end"

      edits = Rewriter.plan_edits(user, vault, full, full, note_target(renamed, "Old.md", "Fresh.md", false))

      assert length(edits) == 1
      assert Rewriter.splice(full, edits) == "[[Fresh]]\n```\n[[Old]]\n```\nand `[[Old]]` end"
    end

    test "path-qualified occurrence stays path-qualified with the new vault-relative path", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "new/Fresh.md"})
      full = "see [[sub/Old]]"

      edits =
        Rewriter.plan_edits(user, vault, full, full, note_target(renamed, "sub/Old.md", "new/Fresh.md", false))

      assert Rewriter.splice(full, edits) == "see [[new/Fresh]]"
    end

    test "ambiguity forces path qualification of a bare occurrence", %{user: user, vault: vault} do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "new/Dup.md"})
      full = "see [[Old]]"

      edits =
        Rewriter.plan_edits(user, vault, full, full, note_target(renamed, "Old.md", "new/Dup.md", true))

      assert Rewriter.splice(full, edits) == "see [[new/Dup]]"
    end

    test "casing follows the new file's actual name; explicit .md form is preserved", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "FRESH Note.md"})
      full = "[[old]] and [[Old.md]]"

      edits = Rewriter.plan_edits(user, vault, full, full, note_target(renamed, "Old.md", "FRESH Note.md", false))

      assert Rewriter.splice(full, edits) == "[[FRESH Note]] and [[FRESH Note.md]]"
    end

    test "already-matching text is a no-op (idempotent)", %{user: user, vault: vault} do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Fresh.md"})
      full = "see [[Fresh]]"

      assert Rewriter.plan_edits(user, vault, full, full, note_target(renamed, "Fresh.md", "Fresh.md", false)) ==
               []
    end

    test "occurrence that resolved to a sibling is NOT rewritten", %{user: user, vault: vault} do
      # Shorter-path sibling wins the pre-rename tiebreak for bare [[Dup]].
      _sibling = Engram.Fixtures.insert_note!(user, vault, %{path: "Dup.md"})
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Renamed.md"})
      full = "see [[Dup]]"

      assert Rewriter.plan_edits(user, vault, full, full, note_target(renamed, "x/Dup.md", "Renamed.md", false)) ==
               []
    end

    test "attachment rename keeps the extension in the link text", %{user: user, vault: vault} do
      renamed = Engram.Fixtures.insert_attachment!(user, vault, %{path: "img/new.png"})
      full = "![[old.png]]"

      target = %{
        kind: :attachment,
        id: renamed.id,
        old_path: "img/old.png",
        new_path: "img/new.png",
        old_basename_hmac: nil,
        collision?: false
      }

      edits = Rewriter.plan_edits(user, vault, full, full, target)
      assert Rewriter.splice(full, edits) == "![[new.png]]"
    end

    test "invalid UTF-8 content goes through the parser's scrub gate without crashing", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Fresh.md"})
      full = "bad " <> <<0xFF>> <> " [[Old]]"
      scrubbed = Engram.Notes.Helpers.scrub_utf8(full, :write)

      edits =
        Rewriter.plan_edits(user, vault, scrubbed, scrubbed, note_target(renamed, "Old.md", "Fresh.md", false))

      assert [%{old: "Old", new: "Fresh"}] = Enum.map(edits, &Map.take(&1, [:old, :new]))
    end
  end
end
```

- [ ] Run: `mix test test/engram/links/rewriter_test.exs` — expect **UndefinedFunctionError** (`Engram.Links.Rewriter.plan_edits/5`).
- [ ] Create `lib/engram/links/rewriter.ex`:

```elixir
defmodule Engram.Links.Rewriter do
  @moduledoc """
  Server-side wikilink/embed rewriter for rename/move propagation
  (issues #648/#1231, Phase 1).

  When a note or attachment is renamed via REST or MCP, referring notes'
  `[[wikilink]]`/`![[embed]]` targets are rewritten to the new name. The
  server is the SINGLE rewriter for every origin EXCEPT plugin-origin
  renames (Obsidian's "Automatically update internal links" owns those) —
  exactly one party rewrites, never both.

  POLICY: the server authors only mechanical, semantics-preserving
  transforms — the rewritten target resolves to the same row the old text
  resolved to, and `!` embed markers, `|alias`, and `#anchor` segments are
  preserved verbatim. The server never authors content the user didn't
  write.

  Rewrites are authored as real Y-updates on the note's canonical doc
  (checkpoint snapshot + `crdt_update_log` tail — `bind/3`'s recipe) and
  appended/broadcast through the SAME persistence path client updates use
  (`CrdtPersistence.update_v1/4`, or the live room when one exists), so
  live editors converge and no content snapshot is ever written.

  Occurrence membership is decided by `Links.pre_rename_winner?/6`
  (pre-rename candidate reconstruction), NOT by current edge target ids —
  the `RebindNoteLinks` jobs the same rename enqueues race this worker and
  flip those ids.
  """

  alias Engram.Links
  alias Engram.Links.Parser

  @note_exts ~w(.md .canvas)

  @doc """
  Plan the target-segment edits for one source note.

  `full_text` is the note's full projected plaintext (what the parser
  runs on); `body` is the Y.Text body (`full_text` minus the frontmatter
  prefix — pass `full_text` itself for plaintext-only callers). Returned
  `rel_start`/`len` are byte offsets into `body`. Idempotent: occurrences
  already carrying the new text plan no edit.
  """
  @spec plan_edits(map(), map(), String.t(), String.t(), map()) :: [map()]
  def plan_edits(user, vault, full_text, body, target) do
    body_start = byte_size(full_text) - byte_size(body)
    old_key = Links.basename_key(target.old_path)

    full_text
    |> Parser.extract()
    |> Enum.filter(fn occ -> Links.basename_key(occ.target) == old_key end)
    |> Enum.filter(fn occ ->
      Links.pre_rename_winner?(user, vault, occ.target, target.kind, target.id, target.old_path)
    end)
    |> Enum.flat_map(fn occ ->
      replacement = replacement_target(occ.target, target)
      rel = occ.target_start - body_start

      cond do
        # Already the new text — idempotent no-op.
        occ.target == replacement -> []
        # Occurrence sits before the body (frontmatter) — the parser already
        # excludes frontmatter, so this is belt-and-suspenders only.
        rel < 0 -> []
        true -> [%{rel_start: rel, len: occ.target_len, old: occ.target, new: replacement}]
      end
    end)
  end

  @doc false
  @spec splice(String.t(), [map()]) :: String.t()
  def splice(text, edits) do
    edits
    |> Enum.sort_by(& &1.rel_start, :desc)
    |> Enum.reduce(text, fn e, acc ->
      binary_part(acc, 0, e.rel_start) <>
        e.new <>
        binary_part(acc, e.rel_start + e.len, byte_size(acc) - e.rel_start - e.len)
    end)
  end

  # Form rule: bare stays bare when the new basename is unambiguous
  # (target.collision? == false); path-qualified when the occurrence was
  # already path-qualified OR the new basename collides. Casing comes from
  # the actual stored new path. The occurrence's extension form is
  # preserved: `[[Old.md]]` -> `[[Fresh.md]]`, `[[Old]]` -> `[[Fresh]]`;
  # non-note extensions (attachments) always keep theirs.
  defp replacement_target(occ_target, %{new_path: new_path, collision?: collision?}) do
    qualified? = String.contains?(occ_target, "/") or collision?
    occ_ext = occ_target |> Path.basename() |> Path.extname() |> String.downcase()
    keep_note_ext? = occ_ext in @note_exts

    base = if qualified?, do: new_path, else: Path.basename(new_path)
    new_ext = Path.extname(base)

    if String.downcase(new_ext) in @note_exts and not keep_note_ext? do
      String.replace_suffix(base, new_ext, "")
    else
      base
    end
  end
end
```

- [ ] Run: `mix test test/engram/links/rewriter_test.exs` — all pass.
- [ ] Commit: `feat(links): rewriter planning core (occurrence selection + form rule)`

---

### Task 4 — Rewriter: Y-doc edit, persist, broadcast (`rewrite_source_note/5`)

The write half. Load the canonical doc (snapshot + tail, inside `Repo.with_tenant`), apply the planned edits as ONE Y-transaction of positional `Yex.Text.delete/insert` calls (UTF-16 offsets — the doc is `offset_kind: :utf16`), encode the delta against the pre-edit state vector, then persist:

- **live room** (`CrdtRegistry.lookup/1` hit): apply the delta inside the room via `SharedDoc.update_doc/2` — the room's `handle_update_v1` appends to the tail-log and broadcasts to observers + fan-out (this IS the client-update path). The room serializes, so no retry needed.
- **roomless**: bounded optimistic concurrency — re-check the tail head `{count, max(inserted_at)}`; unchanged → call `CrdtPersistence.update_v1/4` directly (the documented bare-state-map direct-call path: tail append + head invalidation + `FanoutPacer` broadcast), then enqueue `CheckpointNote` (materializes `notes.content`, deduped per note) — never write a snapshot ourselves. Head advanced → re-read and re-apply, max 3 attempts, then `{:error, :head_advanced}`.
- either way: re-run edge extraction (`Links.replace_links/4` from the post-edit projection) and `CrdtDeliver.announce_ready/4`.
- **legacy rows** (no snapshot, empty tail, doc projects empty but `notes.content` non-empty): the doc holds nothing to edit positionally; route the spliced plaintext through `Notes.upsert_note/4` — the established non-CRDT-origin write path (convergent diff-merge, broadcast, deliver-out), not a snapshot write.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/lib/engram/links/rewriter.ex`
- Test: `/home/open-claw/documents/code-projects/engram/test/engram/links/rewriter_test.exs`

**Interfaces**
- Consumes: `Engram.Crypto.decrypt_crdt_state/2`, `Engram.Crypto.maybe_decrypt_note_fields/2`, `Engram.Notes.CrdtBridge.{doc_from_state/1, project_doc/1, body_of/1, text_name/0}`, `Engram.Notes.CrdtPersistence.{replay_tail/3, update_v1/4}`, `Engram.Notes.CrdtRegistry.lookup/1`, `Yex.Sync.SharedDoc.update_doc/2`, `Yex.Doc.{get_text/2, transaction/3}`, `Yex.Text.{delete/3, insert/3}`, `Yex.{encode_state_vector!/1, encode_state_as_update!/2, apply_update/2}`, `Engram.Notes.Enqueue.enqueue/2`, `Engram.Workers.CheckpointNote.new/1`, `Engram.Notes.CrdtDeliver.announce_ready/4`, `Engram.Notes.upsert_note/4` (legacy branch), `Engram.Links.replace_links/4`.
- Produces:
  - `Engram.Links.Rewriter.rewrite_source_note(user, vault, source_note_id :: binary(), target :: map(), opts :: keyword()) :: {:ok, :rewritten | :noop | :skipped} | {:error, term()}` — `opts[:before_persist]` is a test seam (0-arity fun run between edit authoring and the roomless head re-check; default no-op).
  - `Engram.Links.Rewriter.apply_edits!(doc :: Yex.Doc.t(), body :: String.t(), edits :: [map()]) :: :ok` (`@doc false`).
  - `Engram.Links.Rewriter.build_target(user, vault, kind :: :note | :attachment, id, old_path :: String.t()) :: {:ok, map()} | {:error, :target_gone}`
  - `Engram.Links.Rewriter.rewrite_for_note_rename(user, vault, renamed_note_id, old_path) :: :ok | {:error, term()}` (+ `rewrite_for_attachment_rename/4`) — synchronous full walk (spec-named entry points; the Oban worker chunks the same primitives).

**Steps**

- [ ] Append failing tests to `test/engram/links/rewriter_test.exs`:

```elixir
  alias Engram.Notes
  alias Engram.Notes.Note

  defp raw_note!(user, id) do
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get(Note, id) end)
    raw
  end

  describe "rewrite_source_note/5" do
    test "rewrites the doc via a tail-log Y-update and re-extracts edges", %{
      user: user,
      vault: vault
    } do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})

      content = "See [[Old]] and ![[Old|x]]."
      {:ok, source} = Notes.upsert_note(user, vault, %{"path" => "Source.md", "content" => content})
      :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))

      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")
      assert {:ok, :rewritten} = Rewriter.rewrite_source_note(user, vault, source.id, target)

      {:ok, text} = Notes.authoritative_content(user, raw_note!(user, source.id))
      assert text == "See [[Fresh]] and ![[Fresh|x]]."

      # Edges re-extracted: both now bind to the renamed note under its new text.
      links = Links.links_for_note(user, source.id)
      assert Enum.map(links, & &1.target_text) == ["Fresh", "Fresh"]
      assert Enum.all?(links, &(&1.target_note_id == renamed.id))
    end

    test "second run is a no-op (idempotent)", %{user: user, vault: vault} do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
      {:ok, source} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "[[Old]]"})
      :ok = Links.replace_links(user, vault, source.id, Parser.extract("[[Old]]"))

      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")
      assert {:ok, :rewritten} = Rewriter.rewrite_source_note(user, vault, source.id, target)
      assert {:ok, :noop} = Rewriter.rewrite_source_note(user, vault, source.id, target)
    end

    test "missing / deleted source note is skipped", %{user: user, vault: vault} do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")

      assert {:ok, :skipped} =
               Rewriter.rewrite_source_note(user, vault, Ecto.UUID.generate(), target)
    end

    test "head advancing between load and append triggers a bounded retry that converges", %{
      user: user,
      vault: vault
    } do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
      {:ok, source} = Notes.upsert_note(user, vault, %{"path" => "R.md", "content" => "keep [[Old]]"})
      :ok = Links.replace_links(user, vault, source.id, Parser.extract("keep [[Old]]"))
      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")

      # Simulate a client edit landing in the race window exactly once:
      # append a real tail update (an insert at offset 0) built from the
      # note's current durable state.
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      before_persist = fn ->
        if Agent.get_and_update(agent, fn n -> {n, n + 1} end) == 0 do
          raw = raw_note!(user, source.id)
          {:ok, snapshot} = Engram.Crypto.decrypt_crdt_state(raw, user)
          {:ok, doc} = Engram.Notes.CrdtBridge.doc_from_state(snapshot)

          {:ok, _} =
            Repo.with_tenant(user.id, fn ->
              Engram.Notes.CrdtPersistence.replay_tail(doc, user, source.id)
            end)

          sv = Yex.encode_state_vector!(doc)
          text = Yex.Doc.get_text(doc, Engram.Notes.CrdtBridge.text_name())
          Yex.Text.insert(text, 0, "EDIT ")
          delta = Yex.encode_state_as_update!(doc, sv)

          _ =
            Engram.Notes.CrdtPersistence.update_v1(
              %{user_id: user.id, vault_id: vault.id, note_id: source.id},
              delta,
              nil,
              doc
            )
        end

        :ok
      end

      assert {:ok, :rewritten} =
               Rewriter.rewrite_source_note(user, vault, source.id, target,
                 before_persist: before_persist
               )

      {:ok, text} = Notes.authoritative_content(user, raw_note!(user, source.id))
      # BOTH survive: the concurrent client edit and the rewrite.
      assert text == "EDIT keep [[Fresh]]"
    end

    test "a head that advances on every attempt exhausts the retry budget", %{
      user: user,
      vault: vault
    } do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
      {:ok, source} = Notes.upsert_note(user, vault, %{"path" => "R2.md", "content" => "[[Old]]"})
      :ok = Links.replace_links(user, vault, source.id, Parser.extract("[[Old]]"))
      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")

      always_advance = fn ->
        {:ok, _} =
          Repo.with_tenant(user.id, fn ->
            %Engram.Notes.CrdtUpdateLog{}
            |> Engram.Notes.CrdtUpdateLog.changeset(%{
              note_id: source.id,
              user_id: user.id,
              vault_id: vault.id,
              update_ciphertext: <<0>>,
              update_nonce: <<0>>
            })
            |> Repo.insert()
          end)

        :ok
      end

      assert {:error, :head_advanced} =
               Rewriter.rewrite_source_note(user, vault, source.id, target,
                 before_persist: always_advance
               )
    end

    test "legacy row (no CRDT state) rewrites through upsert_note", %{user: user, vault: vault} do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
      # A fixture-inserted note has content but NO crdt_state and NO tail.
      legacy = Engram.Fixtures.insert_note!(user, vault, %{path: "L.md", content: "see [[Old]]"})
      :ok = Links.replace_links(user, vault, legacy.id, Parser.extract("see [[Old]]"))

      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")
      assert {:ok, :rewritten} = Rewriter.rewrite_source_note(user, vault, legacy.id, target)

      {:ok, note} = Notes.get_note(user, vault, "L.md")
      assert note.content == "see [[Fresh]]"
    end
  end

  describe "build_target/5" do
    test "derives new_path and collision from the live row", %{user: user, vault: vault} do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "sub/Fresh.md", "content" => "x"})
      {:ok, _dup} = Notes.upsert_note(user, vault, %{"path" => "other/Fresh.md", "content" => "y"})

      assert {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")
      assert target.new_path == "sub/Fresh.md"
      assert target.collision?
      assert is_binary(target.old_basename_hmac)
    end

    test "gone target row errors", %{user: user, vault: vault} do
      assert {:error, :target_gone} =
               Rewriter.build_target(user, vault, :note, Ecto.UUID.generate(), "Old.md")
    end
  end
```

- [ ] Run: `mix test test/engram/links/rewriter_test.exs` — expect **UndefinedFunctionError** (`Rewriter.build_target/5`, `Rewriter.rewrite_source_note/4,5`).
- [ ] Implement in `lib/engram/links/rewriter.ex`. Add aliases at the top and the write half:

```elixir
  import Ecto.Query

  alias Engram.{Crypto, Repo}
  alias Engram.Attachments.Attachment
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Logger.Metadata
  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtDeliver, CrdtPersistence, CrdtRegistry, CrdtUpdateLog, Enqueue, Note}
  alias Yex.Sync.SharedDoc

  require Logger

  @max_persist_attempts 3
  @start_cursor "00000000-0000-0000-0000-000000000000"
  @walk_batch 100

  @doc """
  Build the rewrite target spec for a renamed note/attachment. `old_path`
  is the pre-rename vault-relative path (plaintext, resolved by the caller
  — the worker recovers it from the rename tombstone; it never rides Oban
  args). `new_path`/casing come from the row's CURRENT decrypted path, so
  a rename-of-rename always rewrites toward the latest name.
  """
  @spec build_target(map(), map(), :note | :attachment, binary(), String.t()) ::
          {:ok, map()} | {:error, :target_gone}
  def build_target(user, vault, kind, id, old_path) do
    with {:ok, new_path} <- current_path(user, vault, kind, id) do
      {:ok,
       %{
         kind: kind,
         id: id,
         old_path: old_path,
         new_path: new_path,
         old_basename_hmac: Links.basename_hmac(user, Links.basename_key(old_path)),
         collision?: Links.live_basename_count(user, vault, Links.basename_key(new_path)) > 1
       }}
    end
  end

  defp current_path(user, vault, :note, id) do
    row =
      Repo.one(
        from(n in Note,
          where:
            n.id == ^id and n.user_id == ^user.id and n.vault_id == ^vault.id and
              n.kind == "note" and is_nil(n.deleted_at)
        ),
        skip_tenant_check: true
      )

    with %Note{} = note <- row,
         {:ok, %{path: path}} when is_binary(path) <- Crypto.maybe_decrypt_note_fields(note, user) do
      {:ok, path}
    else
      _ -> {:error, :target_gone}
    end
  end

  defp current_path(user, vault, :attachment, id) do
    row =
      Repo.one(
        from(a in Attachment,
          where:
            a.id == ^id and a.user_id == ^user.id and a.vault_id == ^vault.id and
              is_nil(a.deleted_at)
        ),
        skip_tenant_check: true
      )

    with %Attachment{} = att <- row,
         {:ok, %{path: path}} when is_binary(path) <-
           Crypto.maybe_decrypt_attachment_fields(att, user) do
      {:ok, path}
    else
      _ -> {:error, :target_gone}
    end
  end

  @doc """
  Distinct source-note ids with an edge whose `target_basename_hmac`
  matches the renamed row's OLD basename. Keyed on the hmac (indexed), not
  on current edge target ids — `RebindNoteLinks` flips ids concurrently
  but never rewrites the stored hmac/text, so this set is stable however
  the rename-enqueued jobs interleave.
  """
  @spec source_note_ids(map(), map(), binary(), binary(), pos_integer()) :: [binary()]
  def source_note_ids(user, vault, old_basename_hmac, cursor, limit) do
    Repo.all(
      from(l in Engram.Links.NoteLink,
        where:
          l.user_id == ^user.id and l.vault_id == ^vault.id and
            l.target_basename_hmac == ^old_basename_hmac and
            l.source_note_id > ^cursor,
        distinct: true,
        select: l.source_note_id,
        order_by: [asc: l.source_note_id],
        limit: ^limit
      ),
      skip_tenant_check: true
    )
  end

  @doc "Synchronous full walk for a renamed note (spec entry point; the Oban worker chunks the same primitives)."
  @spec rewrite_for_note_rename(map(), map(), binary(), String.t()) :: :ok | {:error, term()}
  def rewrite_for_note_rename(user, vault, renamed_note_id, old_path) do
    with {:ok, target} <- build_target(user, vault, :note, renamed_note_id, old_path) do
      walk(user, vault, target, @start_cursor)
    end
  end

  @doc "Attachment variant of `rewrite_for_note_rename/4`."
  @spec rewrite_for_attachment_rename(map(), map(), binary(), String.t()) :: :ok | {:error, term()}
  def rewrite_for_attachment_rename(user, vault, attachment_id, old_path) do
    with {:ok, target} <- build_target(user, vault, :attachment, attachment_id, old_path) do
      walk(user, vault, target, @start_cursor)
    end
  end

  defp walk(user, vault, target, cursor) do
    case source_note_ids(user, vault, target.old_basename_hmac, cursor, @walk_batch) do
      [] ->
        :ok

      ids ->
        Enum.each(ids, fn id -> _ = rewrite_source_note(user, vault, id, target) end)
        if length(ids) == @walk_batch, do: walk(user, vault, target, List.last(ids)), else: :ok
    end
  end

  @doc """
  Rewrite one source note. Loads the canonical doc (snapshot + tail),
  plans edits, authors them as ONE Y-text transaction, and persists the
  delta through the client-update path (live room when one exists, direct
  `CrdtPersistence.update_v1/4` append otherwise). Bounded optimistic
  retry when the tail head advances under a roomless append.

  `opts[:before_persist]` — test seam, a 0-arity fun run between edit
  authoring and the roomless head re-check.
  """
  @spec rewrite_source_note(map(), map(), binary(), map(), keyword()) ::
          {:ok, :rewritten | :noop | :skipped} | {:error, term()}
  def rewrite_source_note(user, vault, source_note_id, target, opts \\ []) do
    before_persist = Keyword.get(opts, :before_persist, fn -> :ok end)
    attempt(user, vault, source_note_id, target, before_persist, 1)
  end

  defp attempt(user, vault, source_note_id, target, before_persist, n) do
    case load_doc(user, source_note_id) do
      :skip ->
        {:ok, :skipped}

      {:error, reason} ->
        {:error, reason}

      {:legacy, note, content} ->
        rewrite_legacy(user, vault, note, content, target)

      {:loaded, note, doc, head} ->
        full = CrdtBridge.project_doc(doc)
        body = CrdtBridge.body_of(doc)

        case plan_edits(user, vault, full, body, target) do
          [] ->
            {:ok, :noop}

          edits ->
            sv_before = Yex.encode_state_vector!(doc)
            :ok = apply_edits!(doc, body, edits)
            delta = Yex.encode_state_as_update!(doc, sv_before)
            _ = before_persist.()
            persist(user, vault, note, doc, delta, head, target, before_persist, n)
        end
    end
  end

  # Snapshot + tail — bind/3's recipe, same as Notes.maybe_merge_crdt/4 and
  # Workers.CheckpointNote.rebuild_detached/3. `head` is {tail row count,
  # max inserted_at} captured in the SAME tenant transaction as the replay.
  defp load_doc(user, note_id) do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)

    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        case Repo.get(Note, note_id) do
          nil ->
            :skip

          %Note{deleted_at: deleted_at} when not is_nil(deleted_at) ->
            :skip

          %Note{} = note ->
            case Crypto.decrypt_crdt_state(note, user) do
              {:error, reason} ->
                {:error, reason}

              {:ok, snapshot} ->
                if is_binary(snapshot), do: :ok = Yex.apply_update(doc, snapshot)
                applied = CrdtPersistence.replay_tail(doc, user, note_id)
                head = tail_head(note_id)

                if is_nil(snapshot) and applied == [] and CrdtBridge.project_doc(doc) == "" do
                  case Crypto.maybe_decrypt_note_fields(note, user) do
                    {:ok, decrypted} -> {:legacy, note, decrypted.content || ""}
                    {:error, reason} -> {:error, reason}
                  end
                else
                  {:loaded, note, doc, head}
                end
            end
        end
      end)

    result
  end

  # Runs inside the caller's Repo.with_tenant (crdt_update_log is RLS-scoped).
  defp tail_head(note_id) do
    Repo.one(
      from(l in CrdtUpdateLog,
        where: l.note_id == ^note_id,
        select: {count(l.id), max(l.inserted_at)}
      )
    )
  end

  @doc false
  @spec apply_edits!(Yex.Doc.t(), String.t(), [map()]) :: :ok
  def apply_edits!(doc, body, edits) do
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())

    Yex.Doc.transaction(doc, "link_rewrite", fn ->
      edits
      |> Enum.sort_by(& &1.rel_start, :desc)
      |> Enum.each(fn e ->
        off = utf16_len(binary_part(body, 0, e.rel_start))
        len = utf16_len(binary_part(body, e.rel_start, e.len))
        Yex.Text.delete(text, off, len)
        Yex.Text.insert(text, off, e.new)
      end)
    end)

    :ok
  end

  # The doc is offset_kind: :utf16 (CrdtBridge.new_doc/0) — Yex.Text
  # indices are UTF-16 code units, not bytes.
  defp utf16_len(s) do
    s |> :unicode.characters_to_binary(:utf8, {:utf16, :big}) |> byte_size() |> div(2)
  end

  defp persist(user, vault, note, doc, delta, head_at_load, target, before_persist, n) do
    case CrdtRegistry.lookup(note.id) do
      nil ->
        persist_roomless(user, vault, note, doc, delta, head_at_load, target, before_persist, n)

      room ->
        # The room owns the doc and serializes writes; its update_v1 hook
        # appends the delta to the tail-log, broadcasts the frame to every
        # observer, and fans out — the client-update path, verbatim.
        room_apply(room, note.id, fn room_doc ->
          _ = Yex.apply_update(room_doc, delta)
          :ok
        end)

        finish(user, vault, note, doc)
    end
  end

  defp persist_roomless(user, vault, note, doc, delta, head_at_load, target, before_persist, n) do
    {:ok, head_now} = Repo.with_tenant(user.id, fn -> tail_head(note.id) end)

    cond do
      head_now == head_at_load ->
        # Direct call on the documented bare-state-map path: encrypted
        # tail-log append + crdt_head invalidation + FanoutPacer broadcast.
        _ =
          CrdtPersistence.update_v1(
            %{user_id: user.id, vault_id: vault.id, note_id: note.id},
            delta,
            nil,
            doc
          )

        # Roomless append leaves notes.content unmaterialized; the deduped
        # checkpoint worker owns materialization (never a snapshot write here).
        _ =
          Enqueue.enqueue(
            Engram.Workers.CheckpointNote.new(%{
              user_id: user.id,
              vault_id: vault.id,
              note_id: note.id
            }),
            "crdt_checkpoint"
          )

        finish(user, vault, note, doc)

      n < @max_persist_attempts ->
        attempt(user, vault, note.id, target, before_persist, n + 1)

      true ->
        {:error, :head_advanced}
    end
  end

  defp finish(user, vault, note, doc) do
    new_full = CrdtBridge.project_doc(doc)
    :ok = Links.replace_links(user, vault, note.id, Parser.extract(new_full))

    _ =
      case Crypto.maybe_decrypt_note_fields(note, user) do
        {:ok, %{path: path}} when is_binary(path) ->
          CrdtDeliver.announce_ready(user.id, vault.id, path, note.id)

        _ ->
          :ok
      end

    {:ok, :rewritten}
  end

  # Legacy/pre-CRDT row: no Y-text to edit positionally. Route the spliced
  # plaintext through the established non-CRDT-origin write path
  # (upsert_note = convergent diff-merge + broadcast + deliver-out) — a
  # diff-based write, not a snapshot clobber.
  defp rewrite_legacy(user, vault, note, content, target) do
    case plan_edits(user, vault, content, content, target) do
      [] ->
        {:ok, :noop}

      edits ->
        new_text = splice(content, edits)

        with {:ok, %{path: path}} when is_binary(path) <-
               Crypto.maybe_decrypt_note_fields(note, user),
             {:ok, _updated} <-
               Notes.upsert_note(user, vault, %{"path" => path, "content" => new_text}) do
          :ok = Links.replace_links(user, vault, note.id, Parser.extract(new_text))
          {:ok, :rewritten}
        else
          {:ok, _no_path} -> {:error, :path_undecryptable}
          {:error, reason} -> {:error, reason}
          {:stale_base, _} -> {:error, :stale_base}
        end
    end
  end

  # Guarded room call — same exit taxonomy as CrdtDeliver.room_apply/3: a
  # room mid auto-exit is benign (the tail append still happened? NO — on a
  # dead room nothing was appended, so fall through to a fresh roomless
  # attempt is NOT safe either; log and let the worker's per-source error
  # isolation surface it. In practice :noproc means the room exited between
  # lookup and call; the next job attempt re-runs cleanly.)
  defp room_apply(room, note_id, fun) do
    SharedDoc.update_doc(room, fun)
  catch
    :exit, {:noproc, _} ->
      :ok

    :exit, {:normal, _} ->
      :ok

    :exit, {:shutdown, _} ->
      :ok

    :exit, reason ->
      Logger.error(
        "link rewrite room push exited",
        Metadata.with_category(:error, :sync, note_id: note_id, reason: inspect(reason))
      )

      :ok
  end
```

- [ ] Run: `mix test test/engram/links/rewriter_test.exs` — all pass (the `authoritative_content` assertions prove the rewrite lives in the durable doc, not the content façade).
- [ ] Run: `mix test test/engram/links_test.exs test/engram/links_lifecycle_test.exs` — no regressions.
- [ ] Commit: `feat(links): rewriter Y-doc edit + client-path persistence with bounded retry`

---

### Task 5 — Oban worker `Engram.Workers.RewriteNoteLinks`

Async chunked cursor chain over source notes. NO `unique:` (BackfillNoteLinks precedent — a cursor worker's self-re-enqueue collides with its own `executing` row and the chain dies after one batch). Args are ids + base64 HMACs only; the old plaintext path is recovered at run time from the rename tombstone (both `rename_note` and `move_attachment` insert one at the old path). Per-source-note error isolation with warn logs (ids only) + telemetry.

**Files**
- Create: `/home/open-claw/documents/code-projects/engram/lib/engram/workers/rewrite_note_links.ex`
- Test: `/home/open-claw/documents/code-projects/engram/test/engram/workers/rewrite_note_links_test.exs`

**Interfaces**
- Consumes: `Engram.Links.Rewriter.{build_target/5, source_note_ids/5, rewrite_source_note/4}`, `Engram.Crypto.RotationGate.check/1`, `Engram.Vaults.get_vault/2`, `Engram.Telemetry.error_kind/1`, tombstone rows (`notes`/`attachments` where `path_hmac` = old path hmac AND `deleted_at` not nil).
- Produces:
  - `Engram.Workers.RewriteNoteLinks.new_for(user_id, vault_id, kind :: :note | :attachment, target_id, old_path_hmac_b64 :: String.t(), old_basename_hmac_b64 :: String.t()) :: Ecto.Changeset.t()` — note: hmac args are ALREADY base64 (both enqueue sites hold b64 or raw-with-trivial-encode; see Task 6).
  - Telemetry event `[:engram, :links, :rewrite, :failed]`, measurements `%{count: 1}`, metadata `%{reason: error_kind_atom}`.

**Steps**

- [ ] Create `test/engram/workers/rewrite_note_links_test.exs`:

```elixir
defmodule Engram.Workers.RewriteNoteLinksTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Notes
  alias Engram.Workers.RewriteNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp seed_rename!(user, vault) do
    # Real rename so the OLD-path tombstone exists (the worker recovers
    # old_path from it): create at Old.md, rename to Fresh.md.
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
    {:ok, renamed} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
    {note.id, renamed}
  end

  defp seed_source!(user, vault, path, content) do
    {:ok, source} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content})
    :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))
    source
  end

  defp args_for(user, vault, renamed) do
    %{
      "user_id" => user.id,
      "vault_id" => vault.id,
      "target_kind" => "note",
      "target_id" => renamed.id,
      "old_path_hmac" => old_path_hmac_b64(user, "Old.md"),
      "old_basename_hmac" => Base.encode64(Links.basename_hmac(user, Links.basename_key("Old.md")))
    }
  end

  defp old_path_hmac_b64(user, path) do
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    Base.encode64(Engram.Crypto.hmac_field(filter_key, path))
  end

  defp authoritative!(user, note_id) do
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get(Engram.Notes.Note, note_id) end)
    {:ok, text} = Notes.authoritative_content(user, raw)
    text
  end

  test "rewrites every source note and chains by cursor", %{user: user, vault: vault} do
    {_old_id, renamed} = seed_rename!(user, vault)
    sources = for i <- 1..3, do: seed_source!(user, vault, "S#{i}.md", "see [[Old]] #{i}")

    args = Map.put(args_for(user, vault, renamed), "batch_size", 2)
    assert :ok = perform_job(RewriteNoteLinks, args)

    # Batch of 2 full -> successor enqueued with a cursor.
    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert job.args["cursor"] > "00000000-0000-0000-0000-000000000000"
    assert :ok = perform_job(RewriteNoteLinks, job.args)

    for {s, i} <- Enum.with_index(sources, 1) do
      assert authoritative!(user, s.id) == "see [[Fresh]] #{i}"
    end
  end

  test "no unique option: two identical jobs both insert (cursor-chain regression)", %{
    user: user,
    vault: vault
  } do
    {_old_id, renamed} = seed_rename!(user, vault)
    args = args_for(user, vault, renamed)

    assert {:ok, %Oban.Job{id: id1}} = Oban.insert(RewriteNoteLinks.new(args))
    assert {:ok, %Oban.Job{id: id2, conflict?: false}} = Oban.insert(RewriteNoteLinks.new(args))
    refute id1 == id2
  end

  test "per-source failure is isolated: the healthy sibling still rewrites", %{
    user: user,
    vault: vault
  } do
    {_old_id, renamed} = seed_rename!(user, vault)
    bad = seed_source!(user, vault, "Bad.md", "see [[Old]]")
    good = seed_source!(user, vault, "Good.md", "see [[Old]]")

    # Corrupt the bad source's CRDT snapshot so decrypt fails.
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        from(n in Engram.Notes.Note, where: n.id == ^bad.id)
        |> Repo.update_all(set: [crdt_state_ciphertext: <<1, 2, 3>>, crdt_state_nonce: <<0>>])
      end)

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :links, :rewrite, :failed]])
    on_exit(fn -> :telemetry.detach(ref) end)

    assert :ok = perform_job(RewriteNoteLinks, args_for(user, vault, renamed))

    assert authoritative!(user, good.id) == "see [[Fresh]]"
    assert_receive {[:engram, :links, :rewrite, :failed], ^ref, %{count: 1}, %{reason: _}}
  end

  test "missing tombstone discards without raising", %{user: user, vault: vault} do
    {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "x"})

    args =
      args_for(user, vault, renamed)
      |> Map.put("old_path_hmac", old_path_hmac_b64(user, "NeverExisted.md"))

    assert {:discard, :old_path_unrecoverable} = perform_job(RewriteNoteLinks, args)
  end
end
```

- [ ] Run: `mix test test/engram/workers/rewrite_note_links_test.exs` — expect **UndefinedFunctionError** (`Engram.Workers.RewriteNoteLinks.new/1`).
- [ ] Create `lib/engram/workers/rewrite_note_links.ex`:

```elixir
defmodule Engram.Workers.RewriteNoteLinks do
  @moduledoc """
  Oban worker: rewrite `[[wikilink]]`/`![[embed]]` occurrences in every
  note referring to a just-renamed note/attachment (issues #648/#1231,
  Phase 1). Enqueued by `Notes.rename_note/4` and
  `Attachments.move_attachment/4` — REST/MCP origins only; plugin-origin
  renames are rewritten by Obsidian itself and never reach these
  functions, preserving the exactly-one-rewriter invariant.

  Chunked cursor chain over distinct source notes (batch #{100}), keyed on
  the OLD basename hmac of `note_links.target_basename_hmac` — stable
  under the concurrent `RebindNoteLinks` jobs the same rename enqueues.
  Per-source-note error isolation: one failing note logs (ids only) +
  counts `[:engram, :links, :rewrite, :failed]` and the rest proceed.
  A rewrite failure never fails or rolls back the rename.

  Args carry ids + base64 HMACs only (T3.2/H3 — plaintext in
  `oban_jobs.args` JSONB defeats at-rest encryption). The old plaintext
  path is recovered at run time by decrypting the rename tombstone (the
  soft-deleted row both rename paths insert at the old path).
  """

  # No `unique`: a cursor worker re-enqueues its own successor mid-run,
  # which collides with `:incomplete` uniqueness (the running job counts as
  # an in-flight match) and would silently drop the successor, killing the
  # loop after one batch — see Engram.Workers.BackfillNoteLinks. Idempotence
  # comes from the rewrite itself: already-rewritten occurrences plan no
  # edits, so a duplicate job converges as a no-op pass.
  use Oban.Worker, queue: :indexing, max_attempts: 3

  import Ecto.Query

  alias Engram.{Crypto, Repo, Vaults}
  alias Engram.Attachments.Attachment
  alias Engram.Crypto.RotationGate
  alias Engram.Links.Rewriter
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note

  require Logger

  @default_batch_size 100
  @start_cursor "00000000-0000-0000-0000-000000000000"

  @doc """
  Build a rewrite job. `old_path_hmac_b64`/`old_basename_hmac_b64` are
  ALREADY base64 — every enqueue site computes them from plaintext it has
  in scope (T3.2: only the opaque encodings enter `oban_jobs.args`).
  """
  @spec new_for(binary(), binary(), :note | :attachment, binary(), String.t(), String.t()) ::
          Ecto.Changeset.t()
  def new_for(user_id, vault_id, kind, target_id, old_path_hmac_b64, old_basename_hmac_b64) do
    new(%{
      "user_id" => user_id,
      "vault_id" => vault_id,
      "target_kind" => Atom.to_string(kind),
      "target_id" => target_id,
      "old_path_hmac" => old_path_hmac_b64,
      "old_basename_hmac" => old_basename_hmac_b64,
      "cursor" => @start_cursor
    })
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case RotationGate.check(args["user_id"]) do
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :user_not_found} -> {:discard, :user_deleted}
      :ok -> run(args)
    end
  end

  defp run(args) do
    %{
      "user_id" => user_id,
      "vault_id" => vault_id,
      "target_kind" => kind_s,
      "target_id" => target_id,
      "old_path_hmac" => old_path_hmac_b64,
      "old_basename_hmac" => old_basename_hmac_b64
    } = args

    cursor = args["cursor"] || @start_cursor
    batch_size = args["batch_size"] || @default_batch_size
    kind = kind_from(kind_s)

    with {:ok, old_path_hmac} <- decode_b64(old_path_hmac_b64),
         {:ok, old_basename_hmac} <- decode_b64(old_basename_hmac_b64),
         {:ok, user} <- load_user(user_id),
         {:ok, vault} <- load_vault(user, vault_id),
         {:ok, old_path} <- tombstone_old_path(user, vault, kind, old_path_hmac),
         {:ok, target} <- build_target(user, vault, kind, target_id, old_path) do
      ids = Rewriter.source_note_ids(user, vault, old_basename_hmac, cursor, batch_size)
      rewrite_each(user, vault, ids, target)

      if length(ids) == batch_size do
        args
        |> Map.put("cursor", List.last(ids))
        |> new()
        |> Oban.insert()
        |> case do
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
      end
    end
  end

  defp kind_from("attachment"), do: :attachment
  defp kind_from(_), do: :note

  defp decode_b64(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:discard, :invalid_hmac_base64}
    end
  end

  defp load_user(user_id) do
    case Repo.get(Engram.Accounts.User, user_id) do
      nil -> {:discard, :user_deleted}
      user -> {:ok, user}
    end
  end

  defp load_vault(user, vault_id) do
    case Vaults.get_vault(user, vault_id) do
      {:ok, vault} -> {:ok, vault}
      {:error, :not_found} -> {:discard, :vault_deleted}
    end
  end

  defp build_target(user, vault, kind, target_id, old_path) do
    case Rewriter.build_target(user, vault, kind, target_id, old_path) do
      {:ok, target} -> {:ok, target}
      # Renamed row deleted (or renamed again and gone) before we ran —
      # nothing coherent to rewrite toward; a later rename enqueues its own job.
      {:error, :target_gone} -> {:discard, :target_gone}
    end
  end

  # The rename tombstone at the OLD path carries the plaintext we must not
  # put in args: decrypt it. Newest tombstone wins (repeated renames
  # through the same path).
  defp tombstone_old_path(user, vault, :note, old_path_hmac) do
    Repo.one(
      from(n in Note,
        where:
          n.user_id == ^user.id and n.vault_id == ^vault.id and n.kind == "note" and
            n.path_hmac == ^old_path_hmac and not is_nil(n.deleted_at),
        order_by: [desc: n.seq],
        limit: 1
      ),
      skip_tenant_check: true
    )
    |> decrypt_tombstone_path(user, &Crypto.maybe_decrypt_note_fields/2)
  end

  defp tombstone_old_path(user, vault, :attachment, old_path_hmac) do
    Repo.one(
      from(a in Attachment,
        where:
          a.user_id == ^user.id and a.vault_id == ^vault.id and
            a.path_hmac == ^old_path_hmac and not is_nil(a.deleted_at),
        order_by: [desc: a.seq],
        limit: 1
      ),
      skip_tenant_check: true
    )
    |> decrypt_tombstone_path(user, &Crypto.maybe_decrypt_attachment_fields/2)
  end

  defp decrypt_tombstone_path(nil, _user, _decrypt), do: {:discard, :old_path_unrecoverable}

  defp decrypt_tombstone_path(row, user, decrypt) do
    case decrypt.(row, user) do
      {:ok, %{path: path}} when is_binary(path) -> {:ok, path}
      _ -> {:discard, :old_path_unrecoverable}
    end
  end

  defp rewrite_each(user, vault, ids, target) do
    Enum.each(ids, fn source_id ->
      result =
        try do
          Rewriter.rewrite_source_note(user, vault, source_id, target)
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      case result do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          kind = Engram.Telemetry.error_kind(reason)

          Logger.warning(
            "link rewrite failed for source note",
            Metadata.with_category(:warning, :sync,
              note_id: source_id,
              target_id: target.id,
              reason: inspect(kind)
            )
          )

          :telemetry.execute([:engram, :links, :rewrite, :failed], %{count: 1}, %{reason: kind})
      end
    end)
  end
end
```

- [ ] Run: `mix test test/engram/workers/rewrite_note_links_test.exs` — all pass.
- [ ] Run: `mix test test/engram/workers/no_plaintext_args_test.exs` — the source lint stays green (args keys: `user_id`, `vault_id`, `target_kind`, `target_id`, `old_path_hmac`, `old_basename_hmac`, `cursor`, `batch_size` — no banned bare keys).
- [ ] Commit: `feat(links): RewriteNoteLinks cursor-chain worker (no unique, tombstone old-path recovery)`

---

### Task 6 — Wiring (REST + MCP verified) and the PromEx failure counter

Enqueue the worker from `Notes.do_rename_note/6` (next to the existing `RepathNoteIndex` + `RebindNoteLinks` enqueues) and `Attachments.move_attachment/4` (next to its `RebindNoteLinks` enqueues). MCP is verified, not wired: `Handlers.handle("rename_note", ...)` calls `Notes.rename_note/4` (`lib/engram/mcp/handlers.ex:429`) and `Handlers.handle("move_attachment", ...)` calls `Attachments.move_attachment/4` (`handlers.ex:491`) — both route through the wired functions, so tests pin that instead of adding code. Add the failure counter to the existing `Engram.PromEx.Indexing` plugin.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/lib/engram/notes.ex`
- Modify: `/home/open-claw/documents/code-projects/engram/lib/engram/attachments.ex`
- Modify: `/home/open-claw/documents/code-projects/engram/lib/engram/prom_ex/indexing.ex`
- Test: `/home/open-claw/documents/code-projects/engram/test/engram/links/rewrite_wiring_test.exs`

**Interfaces**
- Consumes: `Engram.Workers.RewriteNoteLinks.new_for/6` (Task 5), existing private `old_path_hmac_b64!/2` in `notes.ex`, existing `old_hmac`/`old_basename_hmac` bindings in `attachments.ex`, `Engram.Notes.Enqueue.enqueue/2`.
- Produces: PromEx counter `engram_prom_ex_indexing_link_rewrite_failures_total{reason}` on event `[:engram, :links, :rewrite, :failed]`. (The spec names `engram_link_rewrite_failures_total`; the repo's PromEx custom-metric pattern mandates the `PromEx.metric_prefix(:engram, :indexing)` prefix, so the scraped name carries `prom_ex_indexing` — pattern-conformant, note it in the PR description.)

**Steps**

- [ ] Create `test/engram/links/rewrite_wiring_test.exs`:

```elixir
defmodule Engram.Links.RewriteWiringTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Attachments
  alias Engram.Mcp.Handlers
  alias Engram.Notes
  alias Engram.Workers.RewriteNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "REST-origin note rename enqueues a rewrite job with hmac-only args", %{
    user: user,
    vault: vault
  } do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
    {:ok, _} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")

    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert job.args["target_kind"] == "note"
    assert job.args["target_id"] == note.id
    assert {:ok, _} = Base.decode64(job.args["old_path_hmac"])
    assert {:ok, _} = Base.decode64(job.args["old_basename_hmac"])
    refute Map.has_key?(job.args, "old_path")
  end

  test "no-op rename (same path) enqueues nothing", %{user: user, vault: vault} do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Same.md", "content" => "x"})
    {:ok, _} = Notes.rename_note(user, vault, "Same.md", "Same.md")

    assert all_enqueued(worker: RewriteNoteLinks) == []
  end

  test "attachment move enqueues a rewrite job", %{user: user, vault: vault} do
    att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "img/old.png"})
    {:ok, _} = Attachments.move_attachment(user, vault, "img/old.png", "img/new.png")

    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert job.args["target_kind"] == "attachment"
    assert job.args["target_id"] == att.id
  end

  test "MCP rename_note routes through Notes.rename_note — same enqueue, no extra wiring", %{
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "McpOld.md", "content" => "x"})

    {:ok, _msg} =
      Handlers.handle("rename_note", user, vault, %{
        "old_path" => "McpOld.md",
        "new_path" => "McpNew.md"
      })

    assert [_job] = all_enqueued(worker: RewriteNoteLinks)
  end

  test "MCP move_attachment routes through Attachments.move_attachment", %{
    user: user,
    vault: vault
  } do
    _att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "m/old.png"})

    {:ok, _msg} =
      Handlers.handle("move_attachment", user, vault, %{
        "old_path" => "m/old.png",
        "new_path" => "m/new.png"
      })

    assert [_job] = all_enqueued(worker: RewriteNoteLinks)
  end

  test "PromEx indexing plugin exposes the rewrite-failure counter" do
    metrics =
      [otp_app: :engram]
      |> Engram.PromEx.Indexing.event_metrics()
      |> List.wrap()
      |> Enum.flat_map(& &1.metrics)

    assert Enum.any?(metrics, fn m ->
             m.event_name == [:engram, :links, :rewrite, :failed]
           end)
  end
end
```

  (If the MCP handlers module name differs from `Engram.Mcp.Handlers`, use the module that defines `handle("rename_note", ...)` in `lib/engram/mcp/handlers.ex` — check its `defmodule` line and fix the alias, not the test intent.)
- [ ] Run: `mix test test/engram/links/rewrite_wiring_test.exs` — expect failures: no `RewriteNoteLinks` jobs enqueued; PromEx metric absent.
- [ ] Wire `lib/engram/notes.ex` — in `do_rename_note/6`, inside the `{:ok, {:ok, note}}` success branch, directly after the existing `RepathNoteIndex` enqueue:

```elixir
        # #648/#1231 — server-side link rewrite for REST/MCP-origin renames.
        # Plugin-origin renames never reach rename_note (Obsidian rewrites
        # those itself): exactly one party rewrites. Fire-and-forget: a
        # rewrite failure must never fail the rename.
        _ =
          Enqueue.enqueue(
            Engram.Workers.RewriteNoteLinks.new_for(
              user.id,
              vault.id,
              :note,
              note.id,
              old_path_hmac_b64!(user, old_path),
              Base.encode64(Links.basename_hmac(user, Links.basename_key(old_path)))
            ),
            "rewrite_note_links"
          )
```

- [ ] Wire `lib/engram/attachments.ex` — in `move_attachment/4`, inside the `{:ok, %Attachment{} = att}` / `old_path != new_path` block, after the existing `RebindNoteLinks` enqueues (both hmacs are already bound in scope):

```elixir
              # #648/#1231 — rewrite referring notes' ![[...]]/[[...]] targets.
              _ =
                Enqueue.enqueue(
                  Engram.Workers.RewriteNoteLinks.new_for(
                    user.id,
                    vault.id,
                    :attachment,
                    att.id,
                    Base.encode64(old_hmac),
                    Base.encode64(old_basename_hmac)
                  ),
                  "rewrite_note_links"
                )
```

- [ ] Add the counter to `lib/engram/prom_ex/indexing.ex` — append to the `Event.build` metric list:

```elixir
        counter(
          metric_prefix ++ [:link_rewrite, :failures, :total],
          event_name: [:engram, :links, :rewrite, :failed],
          description: "Per-source-note link-rewrite failures (rename propagation, #648/#1231).",
          tags: [:reason]
        )
```

  and extend the plugin `@moduledoc` metric list with `engram_prom_ex_indexing_link_rewrite_failures_total` — reason is the bounded `Engram.Telemetry.error_kind/1` atom; NEVER note/user/vault ids (cardinality contract).
- [ ] Run: `mix test test/engram/links/rewrite_wiring_test.exs` — all pass.
- [ ] Run: `mix test test/engram/links_lifecycle_test.exs test/engram/workers/no_plaintext_args_test.exs` — lifecycle suite unaffected (new job sits inert in the queue unless drained; if any lifecycle test drains `:indexing` with strict Mox expectations and now trips on the extra job, add the missing stub to that test's setup — do NOT loosen assertions or remove the enqueue).
- [ ] Commit: `feat(links): wire rename/move link-rewrite into REST+MCP origins with failure metric`

---

### Task 7 — Round-trip property + concurrency convergence

Two cross-cutting proofs the spec demands. (1) Round-trip: extract → rename → rewrite → re-extract yields the SAME edge set, now bound at the new target. (2) Concurrency at the Yjs level: the rewrite delta and a concurrent client update converge to identical text in both application orders.

**Files**
- Test: `/home/open-claw/documents/code-projects/engram/test/engram/links/rewriter_roundtrip_test.exs`

**Interfaces**
- Consumes: everything shipped in Tasks 1–6; `Engram.Notes.CrdtBridge.{doc_from_state/1, merge_plaintext/2, body_of/1, text_name/0}`, `Yex.{apply_update/2, encode_state_vector!/1, encode_state_as_update!/2}`.

**Steps**

- [ ] Create `test/engram/links/rewriter_roundtrip_test.exs`:

```elixir
defmodule Engram.Links.RewriterRoundtripTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Links
  alias Engram.Links.{Parser, Rewriter}
  alias Engram.Notes
  alias Engram.Notes.CrdtBridge

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "round trip: extract -> rename -> rewrite -> re-extract gives the same edge set at the new target",
       %{user: user, vault: vault} do
    content = """
    ---
    title: front
    ---
    Intro [[Old]] then ![[Old|pic]] then [[Old#sec]] and [[unrelated]].
    `[[Old]]` stays; so does the fence:
    ```
    [[Old]]
    ```
    """

    {:ok, old} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# target"})
    {:ok, source} = Notes.upsert_note(user, vault, %{"path" => "Src.md", "content" => content})
    :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))

    edges_before = Links.links_for_note(user, source.id)

    {:ok, renamed} = Notes.rename_note(user, vault, "Old.md", "sub/Fresh.md")
    assert renamed.id == old.id

    :ok = Rewriter.rewrite_for_note_rename(user, vault, renamed.id, "Old.md")

    edges_after = Links.links_for_note(user, source.id)

    # Same edge COUNT and shape; alias/anchor/link_type preserved verbatim.
    assert length(edges_after) == length(edges_before)

    assert Enum.map(edges_after, &{&1.alias, &1.anchor, &1.link_type}) ==
             Enum.map(edges_before, &{&1.alias, &1.anchor, &1.link_type})

    # Every edge that pointed at the renamed note still does, under new text.
    rewritten = Enum.filter(edges_after, &(&1.target_note_id == renamed.id))
    assert length(rewritten) == 3
    assert Enum.all?(rewritten, &(&1.target_text == "Fresh"))

    # The unrelated edge is untouched.
    assert Enum.any?(edges_after, &(&1.target_text == "unrelated"))
  end

  test "rewrite delta and a concurrent client update converge in both orders", %{
    user: user,
    vault: vault
  } do
    {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
    base_text = "alpha [[Old]] omega"

    {:ok, %{state: base_state}} = CrdtBridge.merge_plaintext(nil, base_text)
    target = %{
      kind: :note,
      id: renamed.id,
      old_path: "Old.md",
      new_path: "Fresh.md",
      old_basename_hmac: nil,
      collision?: false
    }

    # Author the rewrite delta on copy A.
    {:ok, doc_a} = CrdtBridge.doc_from_state(base_state)
    body_a = CrdtBridge.body_of(doc_a)
    edits = Rewriter.plan_edits(user, vault, CrdtBridge.project_doc(doc_a), body_a, target)
    sv_a = Yex.encode_state_vector!(doc_a)
    :ok = Rewriter.apply_edits!(doc_a, body_a, edits)
    rewrite_delta = Yex.encode_state_as_update!(doc_a, sv_a)

    # Author a concurrent client edit on copy B (insert far from the link).
    {:ok, doc_b} = CrdtBridge.doc_from_state(base_state)
    sv_b = Yex.encode_state_vector!(doc_b)
    text_b = Yex.Doc.get_text(doc_b, CrdtBridge.text_name())
    Yex.Text.insert(text_b, 0, "CLIENT ")
    client_delta = Yex.encode_state_as_update!(doc_b, sv_b)

    # Order 1: rewrite then client.
    {:ok, doc_1} = CrdtBridge.doc_from_state(base_state)
    :ok = Yex.apply_update(doc_1, rewrite_delta)
    :ok = Yex.apply_update(doc_1, client_delta)

    # Order 2: client then rewrite.
    {:ok, doc_2} = CrdtBridge.doc_from_state(base_state)
    :ok = Yex.apply_update(doc_2, client_delta)
    :ok = Yex.apply_update(doc_2, rewrite_delta)

    assert CrdtBridge.body_of(doc_1) == CrdtBridge.body_of(doc_2)
    assert CrdtBridge.body_of(doc_1) == "CLIENT alpha [[Fresh]] omega"
  end
end
```

- [ ] Run: `mix test test/engram/links/rewriter_roundtrip_test.exs` — these should pass against Tasks 1–6 output. Any failure here is a REAL defect in the earlier tasks (most likely offset math or form-rule casing): fix the implementation, never the assertion.
- [ ] Run the full local gauntlet, sequentially: `mix format` → `mix credo --strict` → `mix dialyzer` → `mix test --warnings-as-errors`.
- [ ] Commit: `test(links): rename-rewrite round-trip + CRDT convergence proofs`

---

## Self-Review

- **Spec coverage** — one server-side rewriter, REST/MCP origins only ✓ (Task 6 wires `rename_note`/`move_attachment`; MCP verified to route through both, no extra wiring — pinned by tests); real Y-updates via y_ex, one Y-text transaction per source note ✓ (Task 4 `apply_edits!` under `Yex.Doc.transaction/3`); same persistence path as client updates + CRDT-room broadcast ✓ (`CrdtPersistence.update_v1/4` direct call roomless, `SharedDoc.update_doc/2` when live); `!`/`|alias`/`#anchor` preserved verbatim ✓ (target-segment-only edits, Task 1 offsets); form rule incl. casing + ambiguity qualification ✓ (Task 3); idempotent ✓; bounded optimistic retry, no content snapshots ✓ (Task 4, `CheckpointNote` owns materialization); worker chunked cursor chain, NO `unique:`, hmac/id-only args ✓ (Task 5); failures never fail the rename, warn + `[:engram, :links, :rewrite, :failed]` counter ✓ (Tasks 5–6); moduledoc policy statement ✓; full test matrix incl. round-trip + both-orders concurrency ✓ (Tasks 3, 4, 7); Phase-1 exclusions honored (no folder renames, no web/CRDT-origin, no plugin changes) ✓.
- **Placeholder scan** — no TBDs, no "similar to Task N": every test and implementation step carries the actual code; shared helper shapes (`raw_note!`, `args_for`) are repeated verbatim where a second file needs them.
- **Type consistency** — `target` map (`%{kind, id, old_path, new_path, old_basename_hmac, collision?}`) is built only by `Rewriter.build_target/5` and threaded unchanged through Tasks 3–5; edit maps (`%{rel_start, len, old, new}`) are produced by `plan_edits/5` and consumed by both `apply_edits!/3` (UTF-16 conversion inside) and `splice/2` (byte splicing); worker args use string keys throughout, matching Oban JSONB round-tripping; hmac args are base64 strings end-to-end (`new_for/6` documents it, both enqueue sites comply).
- **Known deviations grounded in code** (flag in the PR): (1) `rewrite_for_note_rename` takes an extra `old_path` arg vs. the spec's 3-arity — required because the spec's step-1 edge query (`target_note_id = renamed id`) is racy against the `RebindNoteLinks` jobs the same rename enqueues; the plan keys the source set on `target_basename_hmac` and membership on pre-rename-winner reconstruction instead. (2) Metric name carries the mandatory PromEx prefix (`engram_prom_ex_indexing_link_rewrite_failures_total`). (3) Legacy (pre-CRDT, stateless) source rows rewrite via `Notes.upsert_note/4` — there is no Y-text to edit positionally, and that path is the codebase's established convergent non-CRDT-origin write.
