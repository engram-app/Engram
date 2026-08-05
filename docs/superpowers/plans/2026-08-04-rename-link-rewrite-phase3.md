# Rename/Move Link-Rewrite Propagation — Phase 3 Implementation Plan (folder renames/moves)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Issues:** engram#648, engram#1231 · **Depends on:** Phases 1–2 (this branch — `Engram.Links.Rewriter`, `Engram.Workers.RewriteNoteLinks` with tombstone + AAD-args old-path recovery, `crdt_rename_rewrites?/1` origin gate)

## Goal

Folder renames and folder moves propagate link rewrites: every path-qualified `[[old-folder/…/Note]]` / `![[old-folder/…/img.png]]` occurrence pointing at a moved row gets its qualified prefix rewritten; bare `[[Note]]` occurrences are untouched (basenames don't change on a folder move, so they still resolve); and — the #1231 rebind — edges whose stored target text was path-qualified under the old folder re-resolve to the moved rows, plus danglers that were waiting on the NEW qualified path get bound. Origin safety holds by construction: the plugin never calls the folder-rename REST surface (verified — see Architecture), so every request reaching `Notes.rename_folder/4` is web/MCP-origin and always rewrites. **The spec's `X-Engram-Origin: obsidian` header machinery is dropped as moot** (Grounding Gap 1).

## Architecture (verified in code)

**The rewriter needs ~zero new semantics.** A folder rename is N note renames where only the folder prefix changes. `Rewriter.rewrite_for_note_rename/4` (rewriter.ex:216) with `old_path` = the note's full pre-move path already does the right thing per moved note:

- **Bare occurrences plan NO edit** — `replacement_target/2` (rewriter.ex:112-125) with `qualified? == false` returns `Path.basename(new_path)` ext-stripped, which equals the occurrence text (basename unchanged), and `plan_edits/5`'s idempotence guard `occ.target == replacement -> []` (rewriter.ex:84-85) drops it. Task 1 pins this with a test.
- **Qualified occurrences get the new prefix** — `qualified? == true` ⇒ `base = new_path` (rewriter.ex:117); membership decided by `Links.pre_rename_winner?/6` (links.ex:332), whose `filter_by_path` (links.ex:271) exact-matches the occurrence's qualified text against the synthetic `{id, old_path}` candidate.
- **Collision nuance (correct, same as note rename):** a bare occurrence whose basename is ambiguous (`collision? == true`, rewriter.ex:113) gets qualified to the new path — the folder move changes the shortest-path tiebreak, so qualifying pins the resolution the occurrence had pre-move.

**The cascade already produces everything the worker needs.** `Notes.do_rename_folder/6` (notes.ex:3773) computes `real_note_updates` — `{note, old_path, new_path, new_folder, title}` tuples with DECRYPTED old paths — and inserts a soft-deleted tombstone at every old path in the SAME transaction (notes.ex:3919-3950). So `RewriteNoteLinks`'s existing tombstone recovery (`tombstone_old_path/4`) works unchanged: folder-cascade jobs need only hmac args (`new_for/7` without ciphertext opts), exactly like REST note renames. **No new worker.** The spec's `FolderRewriteNoteLinks` driver idea is rejected: the side-effect loop (notes.ex:3970) already does a per-note Oban enqueue (`RepathNoteIndex`), so N `RewriteNoteLinks` enqueues are the same order of inserts; each job whose basename has no referring edges exits after one indexed `source_note_ids` query; each job chains its own cursor under the existing no-`unique` rule (rewrite_note_links.ex:26-31).

**Attachments are ALREADY done (Phase 1).** `Attachments.rename_folder/4` (attachments.ex:707) cascades through `move_pairs` → `move_attachment/4`, and `move_attachment` already enqueues `RewriteNoteLinks` (attachments.ex:569-581) plus `RebindNoteLinks` (attachments.ex:555-567) and inserts the old-path tombstone. Task 4 pins this with a test; zero new attachment code.

**Entry points, all funneling into `do_rename_folder`** (one hook covers all):
- `POST /folders/rename` (router.ex:404) → `FoldersController.rename` → `Folders.rename` (folders.ex:74) → `Notes.rename_folder/4` + `Attachments.rename_folder/4`, inside `Folders.atomic/1` (deferred broadcasts + one outer txn).
- MCP `rename_folder` (mcp/handlers.ex:435) → same `Folders.rename`.
- `POST /folders/batch-move` → `Notes.batch_move_folders` (notes.ex:4218) → `rename_folder_gated` → `do_rename_folder` per marker.
- `POST /notes/batch-move` moves NOTES per-id via `move_note_into_folder` (notes.ex:3095) → `rename_note/4` — **already enqueues since Phase 1** (notes.ex:1953-1964). Pin only.

**Who calls the endpoint (the origin truth):** web frontend `useRenameFolder` (frontend/src/api/queries.ts:1782, used in folder-tree.tsx) and MCP. The **plugin does NOT** — its entire folder REST surface is `GET /folders`, `POST /folders`, `DELETE /folders/:segments`, `GET /folders/explicit` (plugin repo src/api.ts:455/605/614/620; no rename call exists). Obsidian folder renames fire per-file `vault.on("rename")` events (plugin src/main.ts:680-681 → `handleRename` in src/sync.ts): notes relocate via `crdt_create` (Phase E2 rename-as-move) — origin-gated by Phase 2's `client_type` — and attachments go `deleteAttachment(oldPath)` + re-upload, never `move_attachment`. So plugin-origin folder renames can never reach the rewrite enqueues, and no header/assign/skip machinery is needed.

**The #1231 rebind closes two ways:**
1. Qualified edges under the old folder (`target_basename_hmac` = a moved note's basename hmac ⇒ IN the rewrite job's source set): text rewrite → `finish/4` → `Links.replace_links` re-extracts + re-resolves — bound to the moved row.
2. Bare edges whose shortest-path winner may FLIP after the move, and pre-typed danglers on the NEW qualified path (`[[new-folder/Note]]` written before the move): closed by the `RebindNoteLinks` bulk fan-out — ONE job per DISTINCT moved basename (issue #1231's "bulk fan-out of distinct basenames"; old and new basename keys are equal on a folder move, so one job per basename mirrors `do_rename_note_inner`'s dedup-when-equal rule).

Interleave safety: `RebindNoteLinks` flips edge target ids but never rewrites stored target text or `target_basename_hmac`; `Rewriter` keys its source set on the hmac and decides membership via `pre_rename_winner?` — both documented order-independent (rewriter.ex:24-27, 190-195).

**Honest residual (Grounding Gap 2):** a pre-existing DANGLING qualified edge under the old folder (`[[old-folder/Ghost]]` where no live row has basename `Ghost` among the moved notes) keeps its old text and stays dangling. No machinery can find it without decrypting every edge (`target_text` is encrypted; the only indexed handle is `target_basename_hmac`, and `Ghost` is not a moved basename) — and none SHOULD: Obsidian itself does not rewrite links to nonexistent files on a folder rename, and the edge binds to nothing either way. Scoped out; noted on #1231.

**Not in scope:** the decrypt-all-edges sweep (rejected above), any `X-Engram-Origin` header (moot), plugin changes (none needed), e2e additions (watch item in Gaps), frontend changes (REST call unchanged).

## Tech Stack

Elixir 1.17+ / Phoenix 1.8+, Ecto + Postgres (RLS tenant scoping), Oban + `Oban.Testing`, ExUnit + `Engram.Fixtures`. No TypeScript changes this phase.

## Global Constraints

- **TDD mandatory**: write the failing test, run it, confirm the exact failure, then implement. Premise-pin tests (Tasks 1 and 4) are EXPECTED green on first run — that is their point (they prove the reuse premise); if any pin is red, STOP and re-plan before writing production code.
- **Sequential gauntlet before push**: `mix format` → `mix credo --strict` → `mix dialyzer` → full `mix test --warnings-as-errors` — SEQUENTIALLY, never concurrently (concurrent dialyzer starves the DB pool → fake failures).
- **No version bumps**: release-please owns `mix.exs`; do not touch it.
- **Oban job args carry ids + base64 HMACs only** — never plaintext path/folder/basename. Folder-cascade jobs need NO ciphertext opts (tombstones exist — see Architecture). `test/engram/workers/no_plaintext_args_test.exs` must stay green; never `noqa` it.
- **Tenant scoping**: this phase adds NO new queries — only enqueues built from plaintext already decrypted inside the cascade.
- **Rewrite/rebind failures never fail or roll back the rename** — enqueue via `Engram.Notes.Enqueue.enqueue/2` (non-raising). Enqueues ride inside whatever outer transaction wraps the cascade (`Folders.atomic/1`, batch txns) — jobs commit or roll back atomically with the rename.
- **Suppression triggers** (`# credo:disable`, `@dialyzer :nowarn`, skipped tests, swallowed exceptions): STOP and state the underlying problem before adding any.
- **No schema changes, no migrations.**
- **Branch**: `feat/rename-link-rewrite` (this worktree), same PR as Phases 1–2 (one initiative = one PR). Never a `ci/` prefix.

---

### Task 1 — Premise pins: `plan_edits` folder-move semantics (test-only)

Prove in the rewriter's own test file that a folder-only move (basename identical) plans NO edit for bare occurrences, rewrites the prefix for qualified ones, and qualifies bare occurrences only under collision. These pin the "zero new rewriter semantics" premise the whole phase stands on.

**Files**
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/test/engram/links/rewriter_test.exs` (extend)

**Interfaces**
- Consumes: `Rewriter.plan_edits/5`, `Rewriter.splice/2`, the file's existing `note_target/4` helper and `%{user, vault}` setup (rewriter_test.exs:16-31).

**Steps**

- [ ] Add a describe block to `test/engram/links/rewriter_test.exs` (below the existing "plan_edits/5 — semantics matrix" describe, same helpers):

```elixir
  describe "plan_edits/5 — folder-only move (Phase 3, #1231)" do
    # A folder rename is N note renames where ONLY the folder prefix changes.
    # These pins prove the Phase 1 machinery already carries Phase 3:
    # basename unchanged ⇒ bare links plan NO edit (replacement_target
    # returns the identical text; the occ.target == replacement guard drops
    # it), qualified links get the new prefix, collision qualifies bare.

    test "bare occurrence plans NO edit when only the folder changed", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "archive/Guide.md"})
      full = "see [[Guide]] and ![[Guide|shown]]"

      assert Rewriter.plan_edits(
               user,
               vault,
               full,
               full,
               note_target(renamed, "docs/Guide.md", "archive/Guide.md", false)
             ) == []
    end

    test "qualified occurrence gets the new folder prefix; bare sibling untouched", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "archive/sub/Guide.md"})
      full = "q [[docs/sub/Guide]] bare [[Guide]] anchored [[docs/sub/Guide#H|x]]"

      edits =
        Rewriter.plan_edits(
          user,
          vault,
          full,
          full,
          note_target(renamed, "docs/sub/Guide.md", "archive/sub/Guide.md", false)
        )

      assert length(edits) == 2

      assert Rewriter.splice(full, edits) ==
               "q [[archive/sub/Guide]] bare [[Guide]] anchored [[archive/sub/Guide#H|x]]"
    end

    test "collision qualifies a bare occurrence toward the NEW folder path", %{
      user: user,
      vault: vault
    } do
      # Two live rows share the basename ⇒ collision? true. The bare link's
      # shortest-path winner could silently flip after the move; qualifying
      # pins the pre-move resolution (same rule as a note rename).
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "archive/Guide.md"})
      _sibling = Engram.Fixtures.insert_note!(user, vault, %{path: "other/Guide.md"})
      full = "see [[Guide]]"

      edits =
        Rewriter.plan_edits(
          user,
          vault,
          full,
          full,
          note_target(renamed, "docs/Guide.md", "archive/Guide.md", true)
        )

      assert Rewriter.splice(full, edits) == "see [[archive/Guide]]"
    end
  end
```

  (Executor note on the collision pin: `plan_edits` also runs `pre_rename_winner?` against the LIVE candidate tables — with the sibling at `other/Guide.md` (path length 14) and the synthetic old candidate `docs/Guide.md` (13), the renamed row wins the shortest-path tiebreak, so the occurrence passes membership. If the assertion fails on membership rather than form, adjust the sibling to a LONGER path — never weaken the assertion.)

- [ ] Run: `mix test test/engram/links/rewriter_test.exs` — ALL green expected, including the three new pins (premise verification, see Global Constraints). If any new pin is red, STOP: the reuse premise is broken; re-plan before Task 2.
- [ ] `mix format`; commit: `test: pin plan_edits folder-only-move semantics (bare=noop, qualified=prefix)`.

---

### Task 2 — Fan-out: `do_rename_folder` enqueues rewrite-per-note + rebind-per-basename

The single production change of this phase. In `do_rename_folder/6`'s post-transaction side-effect loop (which already enqueues `RepathNoteIndex` per note and has the decrypted old/new paths in scope), enqueue one `RewriteNoteLinks` per moved real note, then one `RebindNoteLinks` per DISTINCT moved basename. Markers are already excluded (`real_note_updates`). Covers REST `/folders/rename`, MCP `rename_folder`, and `/folders/batch-move` in one seam (all funnel through `do_rename_folder` — see Architecture).

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/lib/engram/notes.ex`
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/test/engram/links/rewrite_wiring_test.exs` (extend)

**Interfaces**
- Consumes: `RewriteNoteLinks.new_for/7` (no ciphertext opts — tombstone recovery), `RebindNoteLinks.new_for/3` (raw hmac bytes), `Links.basename_hmac/2` + `Links.basename_key/1`, `old_path_hmac_b64!/2` (notes.ex:4367), `Enqueue.enqueue/2`. All already aliased in notes.ex (`RebindNoteLinks`/`RewriteNoteLinks` at notes.ex:33, `Links` in use at notes.ex:4106).
- Produces: no new public functions — behavior only.

**Steps**

- [ ] Extend `test/engram/links/rewrite_wiring_test.exs` with a failing describe (file already has `use Oban.Testing`, the `%{user, vault}` fixture setup, and the `RewriteNoteLinks` alias; add `alias Engram.Workers.RebindNoteLinks` to the alias block):

```elixir
  describe "folder rename fan-out (Phase 3, #648/#1231)" do
    test "enqueues one rewrite per moved note + one rebind per DISTINCT basename", %{
      user: user,
      vault: vault
    } do
      {:ok, a} = Notes.upsert_note(user, vault, %{"path" => "docs/One.md", "content" => "1"})
      {:ok, b} = Notes.upsert_note(user, vault, %{"path" => "docs/sub/One.md", "content" => "1b"})
      {:ok, c} = Notes.upsert_note(user, vault, %{"path" => "docs/Two.md", "content" => "2"})

      # upsert_note-on-CREATE enqueues its own RebindNoteLinks jobs — count
      # the rename's delta, not absolutes.
      rebinds_before = length(all_enqueued(worker: RebindNoteLinks))

      {:ok, 3} = Notes.rename_folder(user, vault, "docs", "archive")

      rewrite_jobs = all_enqueued(worker: RewriteNoteLinks)
      assert length(rewrite_jobs) == 3
      assert Enum.map(rewrite_jobs, & &1.args["target_id"]) |> Enum.sort() ==
               Enum.sort([a.id, b.id, c.id])

      for job <- rewrite_jobs do
        assert job.args["target_kind"] == "note"
        assert {:ok, _} = Base.decode64(job.args["old_path_hmac"])
        assert {:ok, _} = Base.decode64(job.args["old_basename_hmac"])
        refute Map.has_key?(job.args, "old_path")
        refute Map.has_key?(job.args, "old_path_ciphertext")
      end

      # 3 moved notes, 2 distinct basenames (One.md ×2, Two.md) ⇒ delta 2.
      assert length(all_enqueued(worker: RebindNoteLinks)) - rebinds_before == 2
    end

    test "no-op folder rename (same folder) enqueues no rewrite jobs", %{
      user: user,
      vault: vault
    } do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "keep/N.md", "content" => "n"})
      {:ok, _} = Notes.rename_folder(user, vault, "keep", "keep")

      assert all_enqueued(worker: RewriteNoteLinks) == []
    end

    test "batch folder move fans out through the same seam", %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "src/A.md", "content" => "a"})
      {:ok, _marker} = Notes.create_folder_marker(user, vault, "src")
      {:ok, marker} = Notes.get_folder_marker_by_path(user, vault, "src")

      {:ok, %{moved: 1}} =
        Notes.batch_move_folders(user, vault, [marker.id], {:path, "dst"})

      assert [job] = all_enqueued(worker: RewriteNoteLinks)
      assert job.args["target_id"] == note.id
    end

    test "MCP rename_folder routes through Folders.rename — same fan-out", %{
      user: user,
      vault: vault
    } do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "m/N.md", "content" => "n"})

      {:ok, _msg} =
        Handlers.handle("rename_folder", user, vault, %{
          "old_path" => "m",
          "new_path" => "m2"
        })

      assert [_job] = all_enqueued(worker: RewriteNoteLinks)
    end

    test "batch NOTE move already enqueues via rename_note (Phase 1 pin)", %{
      user: user,
      vault: vault
    } do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "bm/N.md", "content" => "n"})

      {:ok, %{moved: 1}} = Notes.batch_move_notes(user, vault, [note.id], {:path, "moved"})

      assert [job] = all_enqueued(worker: RewriteNoteLinks)
      assert job.args["target_id"] == note.id
    end
  end
```

  (Executor notes: (a) marker creation — if `Notes.create_folder_marker/3` / `get_folder_marker_by_path/3` are not the real names, mirror the marker setup used by the existing `batch_move_folders` tests — `grep -rn "batch_move_folders" test/` — and keep the assertion as written; the assertion is the test. (b) The batch-note-move pin is expected green immediately (Phase 1 wiring, notes.ex:1953); it guards #1231's "batch-move" claim against regressions.)

- [ ] Run: `mix test test/engram/links/rewrite_wiring_test.exs` — the first, third, and fourth new tests fail with 0 enqueued `RewriteNoteLinks` jobs (the cascade enqueues nothing today); the no-op test and the batch-note pin pass.
- [ ] Implement in `lib/engram/notes.ex`, inside `do_rename_folder/6`. Replace the existing side-effect loop (notes.ex:3970-4011) so the per-note block hoists the hmac and adds the gated rewrite enqueue — the loop's broadcast code stays byte-identical:

```elixir
      # Side effects outside the transaction — broadcast + reindex + link
      # rewrite fan-out. T3.2 — hmac-only args, never plaintext.
      # Marker rows have no path / no embedding / no basename, skip everything.
      Enum.each(real_note_updates, fn {note, old_note_path, new_path, new_note_folder, _title} ->
        old_path_hmac = old_path_hmac_b64!(user, old_note_path)

        _ =
          Enqueue.enqueue(
            Engram.Workers.RepathNoteIndex.new_debounced(note.id, old_path_hmac: old_path_hmac),
            "repath_note_index"
          )

        # #648/#1231 Phase 3 — a folder rename is N note renames (basename
        # unchanged), so each moved note reuses the Phase 1 rewrite job
        # verbatim: qualified [[old-folder/…]] occurrences get the new
        # prefix; bare [[basename]] occurrences plan no edit (idempotence
        # guard in Rewriter.plan_edits/5). Old-path recovery = the tombstone
        # this very cascade inserted in the same transaction — no ciphertext
        # args. Origin safety is by construction: the plugin never calls the
        # folder-rename REST surface (it renames per-file over CRDT, which
        # Phase 2 gates), so every caller here is web/MCP and must rewrite.
        # Gated on a real move: the idempotent same-folder branch of
        # rename_folder_gated reaches this loop with old == new.
        _ =
          if old_note_path != new_path do
            Enqueue.enqueue(
              RewriteNoteLinks.new_for(
                user.id,
                vault.id,
                :note,
                note.id,
                old_path_hmac,
                Base.encode64(Links.basename_hmac(user, Links.basename_key(old_note_path)))
              ),
              "rewrite_note_links"
            )
          end

        # ... existing #976 broadcast comment + the two broadcast_change
        # calls, UNCHANGED (upsert-before-delete ordering) ...
      end)

      # #1231 — bulk rebind fan-out: ONE RebindNoteLinks per DISTINCT moved
      # basename (old and new basename keys are equal on a folder move, so
      # this is do_rename_note_inner's dedup-when-equal rule at folder
      # scale). Closes what the text rewrite can't: bare-link winners whose
      # shortest-path tiebreak flipped with the move, and pre-typed danglers
      # waiting on the NEW qualified path.
      real_note_updates
      |> Enum.filter(fn {_n, old_p, new_p, _f, _t} -> old_p != new_p end)
      |> Enum.map(fn {_n, old_p, _np, _f, _t} ->
        Links.basename_hmac(user, Links.basename_key(old_p))
      end)
      |> Enum.uniq()
      |> Enum.each(fn hmac ->
        _ = Enqueue.enqueue(RebindNoteLinks.new_for(user.id, vault.id, hmac), "rebind_note_links")
      end)

      {:ok, length(notes)}
```

  Placement detail: the rebind block sits between the existing `Enum.each` and the final `{:ok, length(notes)}` (currently notes.ex:4013). Do not touch the transaction block, tombstone build, or `broadcast_contents`.
- [ ] Run the wiring test file — all green.
- [ ] Run `mix test test/engram/workers/no_plaintext_args_test.exs` (no new arg keys, but the lint walks worker call sites — keep it proven green).
- [ ] Run the adjacent regression surfaces: `mix test test/engram/notes_test.exs test/engram_web/controllers/folders_controller_test.exs` (controller tests now observe extra Oban inserts — they must not assert empty queues; if one does, that is a real conflict to surface, not silence).
- [ ] `mix format`; commit: `feat: folder rename fans out link rewrites + basename rebinds (#1231)`.

---

### Task 3 — Round trip: full folder rename converges text AND edges

Integration proof through `Folders.rename` (the REST/MCP entry) with the real workers: qualified links rewritten (including a source note that itself lives inside the renamed folder), bare links untouched, edges re-bound to the moved rows, and a pre-typed dangler on the new path bound by the rebind fan-out — the #1231 acceptance test.

**Files**
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/test/engram/workers/rewrite_note_links_test.exs` (extend)

**Interfaces**
- Consumes: `Engram.Folders.rename/4`, `perform_job/2` (Oban.Testing), the file's existing `seed_source!/4` + `authoritative!/2` helpers, `Engram.Links.NoteLink` for edge assertions.

**Steps**

- [ ] Add to `test/engram/workers/rewrite_note_links_test.exs` (add `alias Engram.Folders` and `alias Engram.Workers.RebindNoteLinks` to the alias block):

```elixir
  # Drain every enqueued rewrite + rebind job, including cursor successors a
  # rewrite job enqueues mid-run. Loops until the queues are quiet.
  defp drain_link_jobs!() do
    jobs =
      all_enqueued(worker: RewriteNoteLinks) ++ all_enqueued(worker: RebindNoteLinks)

    case jobs do
      [] ->
        :ok

      jobs ->
        for %{worker: w, args: args} <- jobs do
          worker = String.to_existing_atom("Elixir." <> w)
          perform_job(worker, args)
        end

        Repo.delete_all(
          from(j in Oban.Job,
            where: j.worker in ^["Engram.Workers.RewriteNoteLinks", "Engram.Workers.RebindNoteLinks"] and
                     j.state == "available"
          )
        )

        drain_link_jobs!()
    end
  end

  describe "folder rename round trip (Phase 3, #1231)" do
    test "rewrites qualified links, preserves bare links, rebinds edges + danglers", %{
      user: user,
      vault: vault
    } do
      {:ok, guide} =
        Notes.upsert_note(user, vault, %{"path" => "docs/Guide.md", "content" => "# g"})

      # Source OUTSIDE the folder: one qualified + one bare occurrence.
      refs = seed_source!(user, vault, "Refs.md", "see [[docs/Guide]] and [[Guide]]")

      # Source INSIDE the renamed folder referencing a sibling — its own path
      # moves in the same cascade; the rewrite must still land on its doc.
      index = seed_source!(user, vault, "docs/Index.md", "sibling [[docs/Guide]]")

      # Pre-typed dangler on the FUTURE path — must BIND after the move via
      # the rebind fan-out, with NO text change.
      future = seed_source!(user, vault, "Future.md", "soon [[archive/Guide]]")

      {:ok, %{notes: 3, attachments: 0}} = Folders.rename(user, vault, "docs", "archive")
      drain_link_jobs!()

      assert authoritative!(user, refs.id) == "see [[archive/Guide]] and [[Guide]]"
      assert authoritative!(user, index.id) == "sibling [[archive/Guide]]"
      assert authoritative!(user, future.id) == "soon [[archive/Guide]]"

      # #1231: every edge now binds to the moved note — including the
      # previously-dangling Future.md edge.
      edges =
        Repo.all(
          from(l in Engram.Links.NoteLink,
            where:
              l.user_id == ^user.id and l.vault_id == ^vault.id and
                l.source_note_id in ^[refs.id, index.id, future.id],
            select: {l.source_note_id, l.target_note_id}
          ),
          skip_tenant_check: true
        )

      assert length(edges) == 4
      assert Enum.all?(edges, fn {_src, target} -> target == guide.id end)
    end
  end
```

  (Executor notes: (a) `Folders.rename` counts include the cascade total — if the marker-less folder yields `notes: 3` vs another count, trust the DB: the three notes above are `docs/Guide.md`, `docs/Index.md`, and... `Refs.md`/`Future.md` are OUTSIDE — the moved set is `docs/Guide.md` + `docs/Index.md`, so expect `{:ok, %{notes: 2, attachments: 0}}`; fix the match to what the cascade actually reports, NOT the assertions below it. (b) `Refs.md`'s edge count: `[[docs/Guide]]` + `[[Guide]]` = 2 edges, `Index` 1, `Future` 1 ⇒ 4. (c) If `authoritative!` returns frontmatter-prefixed text for these seeds, match with `=~` on the link segments instead of `==` — but keep the `refute … =~ "[[docs/"` spirit by adding `refute authoritative!(user, refs.id) =~ "docs/Guide"`.)

- [ ] Run: `mix test test/engram/workers/rewrite_note_links_test.exs` — the new test fails before Task 2's enqueues exist ONLY if run out of order; on this plan's order it should fail only if the rewrite/rebind machinery misbehaves end-to-end. Investigate any failure as a real bug (Task 1 pinned the semantics; Task 2 pinned the wiring — this test is the seam between them).
- [ ] `mix format`; commit: `test: folder rename round trip — text, edges, dangler rebind (#1231)`.

---

### Task 4 — Attachment-leg premise pin (test-only)

`Folders.rename` already fans out attachment rewrites through `move_attachment` (Phase 1 — attachments.ex:569-581). Pin it so a future refactor of the attachment cascade can't silently drop the enqueue.

**Files**
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-rename-link-rewrite/test/engram/links/rewrite_wiring_test.exs` (extend)

**Steps**

- [ ] Add to the Phase 3 describe from Task 2 (the file already has the `Attachments` alias and `Engram.Fixtures.insert_attachment!`; add `alias Engram.Folders` if not present):

```elixir
    test "folder rename cascades attachment rewrites via move_attachment (Phase 1 pin)", %{
      user: user,
      vault: vault
    } do
      _att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "media/img.png"})
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "media/N.md", "content" => "n"})

      {:ok, %{notes: 1, attachments: 1}} = Folders.rename(user, vault, "media", "assets")

      kinds =
        all_enqueued(worker: RewriteNoteLinks) |> Enum.map(& &1.args["target_kind"]) |> Enum.sort()

      assert kinds == ["attachment", "note"]
    end
```

- [ ] Run: `mix test test/engram/links/rewrite_wiring_test.exs` — expected GREEN on first run (premise pin: the attachment enqueue shipped in Phase 1; only the `"note"` half is Task 2's work). If the `"attachment"` half is missing, STOP — the Phase 1 attachment wiring regressed; find out why before touching anything.
- [ ] `mix format`; commit: `test: pin attachment rewrite fan-out through folder rename cascade`.

---

## Final Verification (before PR update)

- [ ] Sequential gauntlet from the worktree root: `mix format` → `mix credo --strict` → `mix dialyzer` → `mix test --warnings-as-errors` (full suite — the cascade loop change touches folder-rename, batch-move, and controller suites).
- [ ] Confirm no `mix.exs` version diff, no schema/migration diffs, no frontend/plugin diffs.
- [ ] Grep the diff for the dropped spec item: `git diff main -- lib | grep -i "x-engram-origin"` must return nothing — the header was never built (see Grounding Gap 1); the PR body must state why.
- [ ] PR body addition: Phase 3 = one enqueue seam in `do_rename_folder` + rebind fan-out; header machinery dropped with the plugin-truth citation; dangling-under-old-folder residual noted on #1231.

## Self-Review

- [ ] **Spec coverage**: `Notes.rename_folder/4` rewrites ✓ (Task 2, all four REST/MCP/batch entries funnel through `do_rename_folder`); `Attachments.rename_folder/4` rewrites ✓ (already shipping via `move_attachment`, pinned Task 4); plugin skip ✓ (by construction — no endpoint call exists to skip; header dropped, truth documented); folder moves affect only path-qualified occurrences ✓ (Task 1 pins, Task 3 proves end-to-end); #1231 rebind ✓ (rewrite→re-extract for qualified edges + per-basename rebind fan-out for winners/danglers, Task 3's `Future.md` case).
- [ ] **Deviation from spec, stated honestly**: the `X-Engram-Origin: obsidian` header is NOT built. The spec guessed the plugin calls the folder-rename endpoint; the code says it never has (plugin src/api.ts — no rename call; folder renames arrive per-file via CRDT, gated by Phase 2). Building the header would be dead code guarding a caller that doesn't exist.
- [ ] **Placeholder scan**: every code block is complete and anchored to a real file:line; the executor-latitude notes name exact fallbacks (marker-fixture lookup, cascade-count match, frontmatter `=~` fallback) with the assertion invariants that may NOT be weakened.
- [ ] **Idempotence / no-double-work**: duplicate or replayed jobs converge (`plan_edits` idempotence, rewriter.ex:84); no-op folder rename enqueues nothing (`old_note_path != new_path` guard); rebinds deduped per distinct basename.
- [ ] **Atomicity**: enqueues are Oban DB inserts inside the caller's outer transaction (`Folders.atomic/1` / batch txns) — a rolled-back cascade rolls its jobs back with it (broadcasts still leak, the pre-existing documented caveat; unchanged by this phase).
- [ ] **No suppressions added**; `no_plaintext_args_test.exs` green.

## Spec requirements I could not ground in real code (gaps + resolutions)

1. **The plugin folder-rename truth (spec's header requirement is moot).** The spec says "the plugin's folder-rename call adds an `X-Engram-Origin: obsidian` header". There is no such call: the plugin's complete folder REST surface is `GET /folders` (src/api.ts:455), `POST /folders` (:605), `DELETE /folders/:segments` (:614), `GET /folders/explicit` (:620) — `POST /folders/rename` appears nowhere in the plugin repo. Obsidian folder renames fire per-file `vault.on("rename")` (src/main.ts:680-681) → `SyncEngine.handleRename` (src/sync.ts): notes relocate via `crdt_create` rename-as-move (already origin-gated by Phase 2's `client_type`), attachments via `deleteAttachment(oldPath)` + re-upload (never `move_attachment`, so never a rewrite enqueue). **Resolution:** drop the header entirely; folder-rename REST is web/MCP-origin by construction and always rewrites. Documented in the Task 2 code comment and the PR body.
2. **Dangling-under-old-folder residual.** A pre-existing dangling edge `[[old-folder/Ghost]]` (basename `Ghost` not among the moved notes) is unreachable by any fan-out: the only indexed handle is `target_basename_hmac`, `target_text` is encrypted, and `hmac("ghost")` keys nothing that moved. **Resolution:** scoped out as correct-by-comparison — Obsidian also leaves links-to-nonexistent-files untouched on folder rename, and the edge binds to nothing under either text. The one true residual is cosmetic stale text in a link that points nowhere. Leave #1231 open with a comment stating exactly this, or close it citing this plan's Task 3 test — decision belongs to the user, not this plan. A sweep would require decrypting every dangling edge (rejected per spec's own option (b)).
3. **`plan_edits` provably no-op for bare links on folder-only moves.** Proven at rewriter.ex:112-125 (`replacement_target`: `qualified? == false` ⇒ `Path.basename(new_path)` with note-extension stripped = the unchanged basename) + rewriter.ex:84-85 (`occ.target == replacement -> []`). The nearest existing test is the same-text idempotence pin (rewriter_test.exs:129), which is not folder-specific — Task 1's first pin closes that gap explicitly.
4. **Collision behavior on folder moves qualifies bare links.** `build_target` computes `collision?` from the live basename count (rewriter.ex:145) — unchanged by a folder move — so a vault that ALREADY had duplicate basenames will see bare `[[Name]]` links (that resolved to a moved note) rewritten to the qualified new path. This is the note-rename rule applied consistently and pins a resolution the move's tiebreak change could otherwise flip; called out so a reviewer doesn't read it as an unintended folder-move text change.
5. **Fan-out cost accepted without a driver job.** A 1,000-note folder rename enqueues ~1,000 `RewriteNoteLinks` + ≤1,000 `RebindNoteLinks` rows in the cascade transaction — the same order as the `RepathNoteIndex` inserts the loop already does, and each no-referrer job costs one indexed query. The spec's `FolderRewriteNoteLinks` driver would spread enqueues over time at the price of a new worker + a new cursor chain; rejected. If enqueue volume ever measurably hurts, the upgrade path is a driver job that walks `real_note_updates` ids — noted here, not built.
6. **e2e watch item (harness is an API consumer).** `e2e/helpers/api.py` calls `/folders/rename` — harness-origin folder renames will now enqueue rewrites, which is CORRECT (the harness is not Obsidian), but the executor should `grep -rn "folders/rename\|rename_folder" e2e/tests/` and confirm no e2e asserts wikilink text immediately after an API folder rename before merging. As of this plan's research only `test_19_write_isolation.py` touches it (isolation assertions, no wikilink content).
7. **Idempotent same-folder cascade still runs the loop.** `rename_folder_gated`'s `old_folder == new_folder` branch (notes.ex:3632-3633) executes the full cascade; the per-note `old_note_path != new_path` guard keeps that from enqueuing no-op jobs (pinned by Task 2's no-op test). Tombstone inserts in that branch already self-suppress via `on_conflict: :nothing` — pre-existing behavior, unchanged.
