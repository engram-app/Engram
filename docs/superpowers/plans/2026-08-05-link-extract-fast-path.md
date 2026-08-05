# Link-Extract Fast Path + Bind-Time Rename Repair — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Issues:** engram#648/#1231 (rename-rewrite series) · **Depends on:** shipped Phases 1-3 (`Engram.Links.Rewriter`, `Engram.Workers.RewriteNoteLinks` + its +60s sweep from PR #1266)

## Goal

Kill the user-visible 60-90s rename→rewrite latency without touching the paid embedding pipeline. Two event-driven levers, NO polling/timers:

1. **Lever 1 — split link extraction from embedding.** Today `[[link]]` edges are written ONLY inside the embed pipeline (30s trailing debounce + Voyage call) — a new lightweight `ExtractNoteLinks` Oban job runs the cheap parse+HMAC+upsert within ~2s of content landing server-side. Embeddings stay exactly as debounced as they are.
2. **Lever 2 — bind-time repair.** When fresh extraction inserts an edge that lands DANGLING and a recent rename explains it, re-run that rename's rewrite chain immediately instead of waiting for (or, for late arrivals, entirely missing) the +60s sweep.

The +60s sweep stays as backstop in this PR; the final task re-evaluates it with data.

## Architecture — current truth (verified in code)

**Where indexing gets enqueued today (the ONLY edge writers):**

- `Engram.Links.replace_links/4` (`lib/engram/links.ex:63`) is the single edge-persistence primitive: delete-all-for-source + insert_all, wrapped in `Repo.transaction` (`links.ex:101-112`). `note_links` carries `unique_index(:note_links, [:source_note_id, :position])` (`priv/repo/migrations/20260804025327_create_note_links_expand.exs:42`).
- Call sites: `Indexing.index_note/2` `:no_chunks` branch (`lib/engram/indexing.ex:43`), `Indexing.commit_index/1` (`indexing.ex:147`), `Rewriter.finish/4` + `rewrite_legacy/5` post-rewrite (`lib/engram/links/rewriter.ex:453`, `:483`), and the historical backfill worker (`lib/engram/workers/backfill_note_links.ex:255`).
- **No REST path extracts inline.** `upsert_note` only enqueues `EmbedNote.new_debounced` on content-hash change (`lib/engram/notes.ex:427` insert/update leg, `notes.ex:483` moved leg); the batch upsert does the same via `Oban.insert_all` (`notes.ex:2988`, `clamp: false`). Extraction happens when EmbedNote eventually runs `Indexing.index_note` (`lib/engram/workers/embed_note.ex:262`).
- **CRDT path:** keystrokes append to the tail-log (`CrdtPersistence.update_v1/4`, `lib/engram/notes/crdt_persistence.ex:122` — per-batch hot path, runs inside the room GenServer; NOT a viable extraction hook). Materialization is `CrdtCheckpoint.checkpoint/5` driven by `CrdtCheckpointTimer` (settle **5s** / ceiling **60s** / eager **250ms** — `lib/engram/notes/crdt_checkpoint_timer.ex:43-45`) or by the `CheckpointNote` overflow worker; on a real content change it enqueues `EmbedNote.new_debounced` (`lib/engram/notes/crdt_checkpoint.ex:161`). CRDT genesis inserts content `""` (`notes.ex:1132`, `genesis_insert_bare`) — real content only ever lands via checkpoint, so hooking checkpoint covers genesis too.

**The debounce constants:** EmbedNote trailing debounce settle = **30s** (`embed_settle_seconds`, `lib/engram/workers/embed_note.ex:398`), max-wait ceiling = **300s** (`embed_note.ex:400-401`), unique per `note_id` `:incomplete`. Worst honest edge latency today: CRDT checkpoint (≤5-60s) + embed settle (30-300s) + queue time. Two extra traps make it worse: EmbedNote skips entirely when `embed_hash == content_hash` (`embed_note.ex:51-54`), and the Free-tier lifetime embed-token cap `{:cancel}`s the job BEFORE `index_note` runs (`embed_note.ex:101-127`) — a budget-exhausted user's edges currently never update. Lever 1 fixes that class as a side effect.

**Why the rename-rewrite misses:** `RewriteNoteLinks` walks referrers via `note_links.target_basename_hmac` (`lib/engram/workers/rewrite_note_links.ex:164`). An edge not yet extracted at walk time is invisible; PR #1266's sweep re-walks once at +60s (`@sweep_delay_seconds 60`, `rewrite_note_links.ex:73`; terminating branch `:177-197`). An edge that lands **after** rename+60s (offline device, embed backlog) is missed forever until the next rename.

**Lever 2's args source — the answer to the tombstone question:** REST/MCP renames insert a soft-deleted tombstone at the old path (`do_rename_note_inner`, `notes.ex:2044-2093`) but the tombstone does NOT carry the renamed row's id — reconstructing `new_for/7` args from it would need a fragile same-`seq` pair lookup. CRDT-origin relocates insert **no tombstone at all** (`notes.ex:1003-1010`) — the old path exists only as AAD-bound ciphertext inside the enqueued job's args (`enqueue_crdt_rename_rewrite`, `notes.ex:1011-1029`). But **every** rename origin that rewrites (REST `notes.ex:1971-1981`, CRDT `notes.ex:1017-1029`, folder cascade `notes.ex:4010-4024`, attachment move `lib/engram/attachments.ex:572`) leaves a durable, perfectly-formed args record: the `oban_jobs` row itself, retained 7 days by `Oban.Plugins.Pruner` (`config/config.exs:89`). So the repair source is the **prior job row**, not the tombstone — one design covers all four origins including CRDT, and args are copied verbatim (ids + b64 HMACs/ciphertext only, T3.2 preserved by construction). Renames with NO prior job row — plugin/Obsidian-origin, by the one-rewriter invariant — get no repair, correctly: the server must never rewrite those.

**Loop-breaker (lever 2):** the repair re-enqueue is the original args with `"cursor"` reset and `"sweep" => true` — so the repair chain IS a sweep run: it terminates without enqueueing another sweep (`maybe_enqueue_sweep(%{"sweep" => true})`, `rewrite_note_links.ex:185`). Convergence: a repair rewrite changes content → re-extraction produces edges under the NEW basename hmac → no prior-job match → done; a no-op rewrite changes nothing → no re-extraction → no re-trigger. Insert-time `unique` on `[:target_id, :old_basename_hmac]` over `[:available, :scheduled]` dedups repair entries against each other AND against the rename's own still-scheduled sweep (which will do the identical work). Chain successors insert via plain `new/1` with no unique — the no-unique-on-cursor-chains rule (`rewrite_note_links.ex:49-54`) is about a chain's own successor colliding with its `:executing` parent under worker-level `:incomplete` uniqueness; a per-call unique on the single-shot repair ENTRY, scoped to states that never include the executing parent, does not re-create that trap.

**Concurrent-extraction posture:** `ExtractNoteLinks` and the untouched EmbedNote pipeline can both call `replace_links` for one note. Interleaved delete+insert transactions can violate `unique_index([:source_note_id, :position])` (READ COMMITTED: B's delete doesn't see A's uncommitted inserts). Fix at the root, in the one shared function: a per-source-note `pg_advisory_xact_lock` inside `replace_links`' existing transaction serializes every writer (extract worker, embed commit, rewriter, backfill) with one line. Both runs re-read/receive current-parse rows, so last-writer-wins converges.

**`:no_chunks` trap:** honored by construction — `ExtractNoteLinks` never touches `prepare_index`; it calls `Parser.extract` + `replace_links` directly, so a note emptied to `""` extracts `[]` and clears its stale edges the same as any other write.

## Tech Stack

Elixir 1.17+ / Phoenix 1.8+, Ecto + Postgres (RLS tenant scoping, advisory locks), Oban + `Oban.Testing` (`:manual` testing mode — enqueued jobs are real DB rows), ExUnit + `Engram.Fixtures` + `Engram.DataCase`. No frontend/plugin changes. No migrations.

## Global Constraints

- **TDD mandatory**: write the failing test, run it, confirm the exact failure, then implement. Never modify a test to make bad code pass.
- **Sequential gauntlet before push**: `mix format` → `mix credo --strict` → `mix dialyzer` → full `mix test --warnings-as-errors` — SEQUENTIALLY, never concurrently (concurrent dialyzer starves the DB pool → fake failures).
- **No version bumps**: release-please owns `mix.exs`; do not touch it.
- **Oban job args carry ids + base64 HMACs/ciphertexts only** (T3.2/H3). New worker args are `%{note_id: id}` only; repair args are copied verbatim from an existing job row. Keep `test/engram/workers/no_plaintext_args_test.exs` green — never suppress it.
- **Tenant scoping**: worker queries follow the `EmbedNote` precedent — `skip_tenant_check: true` with explicit `user_id`/`vault_id` filters; the `oban_jobs` repair query filters `user_id`+`vault_id` args explicitly (oban_jobs is not a tenant table).
- **Embeddings pipeline UNTOUCHED**: no change to `EmbedNote` scheduling, dedup, budget gate, or `Indexing` — `commit_index` keeps its `replace_links` call (idempotent duplicate; also what backfill/reconcile correctness relies on).
- **Suppression triggers** (`# credo:disable`, `@dialyzer :nowarn`, skipped tests, swallowed exceptions): STOP and state the underlying problem before adding any.
- **No schema changes, no migrations** (the migration linters therefore never fire; do not add any migration to this PR).
- **Branch**: `feat/link-extract-fast-path` (this worktree). Never a `ci/` prefix (gets NO CI).
- Blank line before every `### Task` heading; one PR for the whole initiative.

---

### Task 1 — `Engram.Workers.ExtractNoteLinks`: the fast extraction job

Single-shot, leading-edge-debounced (~2s) Oban job on the existing `:indexing` queue (concurrency 2, `config/config.exs:81`). Leading-edge (no `replace: [:scheduled_at]`) is deliberate: the job reads CURRENT note content at run time, so the first enqueue after a quiet period fixes the latency and later edits within the window are covered by that same read — no trailing-starvation ceiling machinery needed. Unique over `[:available, :scheduled]` (not `:incomplete`): an enqueue during an `:executing` run must insert a fresh job so content changed mid-run gets re-extracted.

**Files**
- Create: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-link-extract-fast-path/lib/engram/workers/extract_note_links.ex`
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-link-extract-fast-path/test/engram/workers/extract_note_links_test.exs` (new)

**Interfaces**
- Produces: `ExtractNoteLinks.new_debounced/1 :: binary() -> Ecto.Changeset.t()` and `perform/1`.
- Consumes: `Engram.Notes.fetch_note_for_worker/1` (`notes.ex:1740`), `Crypto.RotationGate.check/1`, `Crypto.maybe_decrypt_note_fields/2`, `Links.Parser.extract/1`, `Links.replace_links/4`. Repair hook added in Task 4 — `perform` calls a stub `:ok` for now? **No stubs**: Task 1 ships without any repair call; Task 4 adds it.

**Steps**

- [ ] Write the failing test file `test/engram/workers/extract_note_links_test.exs`:

```elixir
defmodule Engram.Workers.ExtractNoteLinksTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Links
  alias Engram.Notes
  alias Engram.Workers.ExtractNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "extracts edges from current note content", %{user: user, vault: vault} do
    {:ok, target} = Notes.upsert_note(user, vault, %{"path" => "Target.md", "content" => "# t"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "see [[Target]]"})

    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id})

    assert [%{target_text: "Target", target_note_id: tid, dangling: false}] =
             Links.links_for_note(user, note.id)

    assert tid == target.id
  end

  test "a note emptied to \"\" clears its stale edges (:no_chunks class)",
       %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "see [[X]]"})
    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id})
    assert [_] = Links.links_for_note(user, note.id)

    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => ""})
    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id})
    assert [] == Links.links_for_note(user, note.id)
  end

  test "missing note discards", %{user: _user} do
    assert {:discard, _} = perform_job(ExtractNoteLinks, %{note_id: Ecto.UUID.generate()})
  end

  test "soft-deleted note discards", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "D.md", "content" => "x [[Y]]"})
    {:ok, _} = Notes.delete_note(user, vault, "D.md")
    assert {:discard, _} = perform_job(ExtractNoteLinks, %{note_id: note.id})
  end

  test "new_debounced dedups per note over available/scheduled", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "a"})

    {:ok, _} = Oban.insert(ExtractNoteLinks.new_debounced(note.id))
    {:ok, _} = Oban.insert(ExtractNoteLinks.new_debounced(note.id))

    assert [job] = all_enqueued(worker: ExtractNoteLinks)
    assert job.args["note_id"] == note.id
    # Leading-edge: ~2s out, never immediate.
    assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
  end
end
```

  (If `Notes.delete_note/3` has a different arity/shape in the current code — the codebase has `delete_note/4` per `links.ex:25` moduledoc — mirror how `test/engram/links_lifecycle_test.exs` soft-deletes a note; the assertion under test is only the `{:discard, _}`.)

- [ ] Run: `mix test test/engram/workers/extract_note_links_test.exs` — confirm failure is the module not existing.
- [ ] Implement `lib/engram/workers/extract_note_links.ex`:

```elixir
defmodule Engram.Workers.ExtractNoteLinks do
  @moduledoc """
  Oban worker: prompt `[[wikilink]]`/`![[embed]]` edge extraction, split off
  the embed pipeline (#648 latency pair, lever 1).

  Historically `note_links` rows were written only inside the indexing pass
  (`Indexing.index_note/2`), which rides EmbedNote's 30s trailing debounce and
  the Voyage budget gate — so a rename inside that window found no referrer
  edge and fell back to the +60s sweep. This job runs the cheap half only
  (regex parse + HMAC resolve + delete/insert; NO embedding, NO Qdrant) within
  ~#{2}s of content landing server-side. The embed pipeline is untouched and
  still re-runs `replace_links` later — that duplicate is idempotent, and
  `replace_links`' per-note advisory lock serializes the two writers.

  Leading-edge debounce: `new_debounced/1` schedules ~2s out and dedups per
  note over `[:available, :scheduled]` ONLY. The job reads CURRENT content at
  run time, so edits landing inside the window are covered by the pending run;
  an edit during an `:executing` run inserts a fresh job (states deliberately
  exclude `:executing`/`:retryable`). No trailing `replace:` — first-edit
  latency is the product requirement, and a run always extracts the newest
  content anyway, so there is nothing for a trailing reschedule to improve.

  Bulk callers (batch upsert) enqueue via `Oban.insert_all`, which ignores
  `unique` — duplicate jobs for one note converge (idempotent, serialized).

  T3.2: args carry the note id only.
  """
  use Oban.Worker,
    queue: :indexing,
    max_attempts: 3,
    unique: [period: 60, keys: [:note_id], states: [:available, :scheduled]]

  alias Engram.Accounts
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Logger.DecryptFailure
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"note_id" => note_id}}) do
    case Engram.Notes.fetch_note_for_worker(note_id) do
      {:discard, _reason} = discard ->
        discard

      {:ok, %Note{} = note} ->
        case RotationGate.check(note.user_id) do
          {:error, :rotation_in_progress} -> {:snooze, 60}
          {:error, :user_not_found} -> {:discard, :user_deleted}
          :ok -> extract(note)
        end
    end
  end

  defp extract(note) do
    user = Accounts.get_user!(note.user_id)

    # Missing vault = orphaned note (same rule as EmbedNote): nothing to do.
    case Repo.get(Vault, note.vault_id, skip_tenant_check: true) do
      nil ->
        {:discard, "vault #{note.vault_id} not found for note #{note.id}"}

      %Vault{} = vault ->
        case Crypto.maybe_decrypt_note_fields(note, user) do
          {:ok, decrypted} ->
            :ok = Links.replace_links(user, vault, note.id, Parser.extract(decrypted.content || ""))
            :ok

          {:error, reason} ->
            DecryptFailure.log("extract_links_decrypt_failed", reason,
              user_id: note.user_id,
              note_id: note.id
            )

            {:error, reason}
        end
    end
  end

  @doc """
  Leading-edge debounced job (~2s, `LINK_EXTRACT_DELAY_SECONDS` via app env).
  """
  @spec new_debounced(binary()) :: Ecto.Changeset.t()
  def new_debounced(note_id) do
    new(%{note_id: note_id}, schedule_in: extract_delay_seconds())
  end

  defp extract_delay_seconds,
    do: Application.get_env(:engram, :link_extract_delay_seconds, 2)
end
```

- [ ] Run the test file — all green.
- [ ] Run `mix test test/engram/workers/no_plaintext_args_test.exs` — the new worker's args (`note_id` only) must pass the lint.
- [ ] `mix format`; commit: `feat: ExtractNoteLinks worker — prompt edge extraction off the embed path`.

---

### Task 2 — Serialize concurrent extraction in `replace_links/4`

Two writers (this worker + the untouched embed pipeline, or two duplicate bulk jobs) interleaving delete+insert can trip `unique_index(:note_links, [:source_note_id, :position])`. Root-cause fix in the ONE shared function: per-source-note `pg_advisory_xact_lock` inside the existing transaction. Every caller (`indexing.ex:43/:147`, `rewriter.ex:453/:483`, `backfill_note_links.ex:255`, the new worker) inherits it.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-link-extract-fast-path/lib/engram/links.ex`
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-link-extract-fast-path/test/engram/links_test.exs` (extend)

**Interfaces**
- `replace_links/4` signature and `:ok` return unchanged. New private `lock_source_note!/1`.

**Steps**

- [ ] Extend `test/engram/links_test.exs` (mirror its existing setup idiom) with a repeated-call convergence pin — the honest test the Ecto sandbox permits (true cross-connection interleaving is untestable there; see Grounding Gaps):

```elixir
  test "replace_links called twice for the same note converges to the last parse",
       %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "x"})

    :ok = Links.replace_links(user, vault, note.id, Parser.extract("a [[One]] b [[Two]]"))
    :ok = Links.replace_links(user, vault, note.id, Parser.extract("a [[Three]]"))

    assert [%{target_text: "Three"}] = Links.links_for_note(user, note.id)
  end
```

- [ ] Run it — it should already pass (sequential calls were always safe). This test pins the contract the lock preserves; the lock itself is the change under review, not a behavior change visible to a single connection.
- [ ] Implement in `lib/engram/links.ex` — inside the existing `Repo.transaction` in `replace_links/4` (`links.ex:101`), first statement:

```elixir
    Repo.transaction(fn ->
      # Serialize concurrent extraction for one source note. Two writers
      # (ExtractNoteLinks fast path + the embed pipeline's commit_index, or
      # duplicate bulk jobs) interleaving this delete+insert under READ
      # COMMITTED can violate unique_index([:source_note_id, :position]):
      # B's DELETE cannot see A's uncommitted inserts. Both runs write a
      # freshly-parsed row set, so strict last-writer-wins under this lock
      # converges. Single lock per txn, taken first — no deadlock ordering.
      lock_source_note!(source_note_id)

      Repo.delete_all(
        ...unchanged...
```

  and add the private helper below `replace_links/4`:

```elixir
  # Transaction-scoped advisory lock keyed on the source note id. Released
  # automatically at commit/rollback; hashtextextended maps the UUID string
  # to the bigint advisory-lock keyspace.
  defp lock_source_note!(source_note_id) do
    %{rows: [[_]]} =
      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        [to_string(source_note_id)]
      )

    :ok
  end
```

- [ ] Run: `mix test test/engram/links_test.exs test/engram/workers/extract_note_links_test.exs test/engram/workers/backfill_note_links_test.exs test/engram/links/rewriter_test.exs` — every existing `replace_links` consumer stays green under the lock.
- [ ] `mix format`; commit: `fix: per-note advisory lock serializes concurrent replace_links writers`.

---

### Task 3 — Wire the fast path at the four content-persistence seams

Enqueue `ExtractNoteLinks.new_debounced` everywhere `EmbedNote.new_debounced` is enqueued **for a content change** — same `prev_hash != content_hash` guards, so no-op writes enqueue nothing. Four sites: REST upsert (two legs), batch upsert, CRDT checkpoint. NOT wired: `RepathNoteIndex`/`ReconcileEmbeddings`/`ReindexKeyword` (embedding maintenance, content unchanged) and the Rewriter (extracts inline already, `rewriter.ex:453/:483`).

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-link-extract-fast-path/lib/engram/notes.ex`
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-link-extract-fast-path/lib/engram/notes/crdt_checkpoint.ex`
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-link-extract-fast-path/test/engram/workers/extract_note_links_test.exs` (extend)

**Interfaces**
- Consumes Task 1's `new_debounced/1` via the existing non-raising `Engram.Notes.Enqueue.enqueue/2` (label `"extract_note_links"`).

**Steps**

- [ ] Extend the worker test file with wiring tests:

```elixir
  describe "wiring" do
    test "REST upsert enqueues extraction on content change, not on no-op",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "W.md", "content" => "v1"})
      assert [%{args: %{"note_id" => id}}] = all_enqueued(worker: ExtractNoteLinks)
      assert id == note.id

      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      # Idempotent re-push of identical content: no version/seq persisted → no job.
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "W.md", "content" => "v1"})
      assert [] == all_enqueued(worker: ExtractNoteLinks)
    end

    test "CRDT checkpoint content change enqueues extraction",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "C.md", "content" => "old"})
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      {:ok, doc} = Engram.Notes.CrdtBridge.doc_from_state(nil)
      text = Yex.Doc.get_text(doc, "content")
      Yex.Text.insert(text, 0, "new [[Linked]]")
      :ok = Engram.Notes.CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

      assert [%{args: %{"note_id" => id}}] = all_enqueued(worker: ExtractNoteLinks)
      assert id == note.id
    end
  end
```

  (Executor note: the CRDT test's doc construction must mirror how `test/engram/notes/crdt_checkpoint_test.exs` — or the nearest existing checkpoint test — builds a doc that materializes a content change; copy that file's construction verbatim if the `Yex.Doc.get_text/2` sketch above differs. The assertion under test is only the enqueue next to the existing `EmbedNote` enqueue.)

- [ ] Run — both fail (no jobs enqueued).
- [ ] Implement:
  - `lib/engram/notes.ex:33` — extend the alias: `alias Engram.Workers.{DeleteNoteIndex, EmbedNote, ExtractNoteLinks, RebindNoteLinks, RewriteNoteLinks}`.
  - `notes.ex:425-428` (insert/update leg) — inside the existing `if prev_hash != note.content_hash do` that enqueues EmbedNote, add the sibling line:

```elixir
          _ =
            if prev_hash != note.content_hash do
              Enqueue.enqueue(EmbedNote.new_debounced(note.id), "embed_note")
              # #648 lever 1 — cheap edge extraction must not ride the embed
              # debounce (30s) or the embed budget gate; ~2s leading edge.
              Enqueue.enqueue(ExtractNoteLinks.new_debounced(note.id), "extract_note_links")
            end
```

  - `notes.ex:481-484` (moved leg) — identical sibling line inside its `if prev_hash != note.content_hash do`.
  - `notes.ex:2981-2992` (`batch_upsert_side_effects`) — extend the bulk insert:

```elixir
    extract_jobs =
      ok_entries
      |> Enum.filter(fn %{result: {:ok, info}} -> info.prev_hash != info.content_hash end)
      |> Enum.map(fn %{result: {:ok, info}} -> ExtractNoteLinks.new_debounced(info.id) end)

    _ = if extract_jobs != [], do: Oban.insert_all(extract_jobs)
```

    (next to the existing `embed_jobs` block; `insert_all` ignores `unique` — duplicates converge under the Task 2 lock, same accepted posture as `EmbedNote clamp: false`.)
  - `lib/engram/notes/crdt_checkpoint.ex:24` — alias becomes `alias Engram.Workers.{EmbedNote, ExtractNoteLinks}`; at `crdt_checkpoint.ex:159-162`, inside `if prev_hash != new_hash do`:

```elixir
              if prev_hash != new_hash do
                _ = Enqueue.enqueue(EmbedNote.new_debounced(note_id), "embed_note")
                # #648 lever 1 — see ExtractNoteLinks moduledoc. Covers the
                # whole CRDT surface (genesis included: content only ever
                # lands in notes.content through this checkpoint).
                _ = Enqueue.enqueue(ExtractNoteLinks.new_debounced(note_id), "extract_note_links")
```

- [ ] Run the worker test file, then the blast radius: `mix test test/engram/notes_test.exs test/engram/notes test/engram/links_lifecycle_test.exs` (existing tests asserting exact `all_enqueued` contents may need the new worker filtered or expected — extend expectations, never delete assertions).
- [ ] `mix format`; commit: `feat: enqueue link extraction at all four content-persistence seams`.

---

### Task 4 — Lever 2: bind-time rename repair from the extraction job

After `replace_links`, if any of the note's edges landed dangling, check whether a **recent rename explains it**: a `RewriteNoteLinks` job row (any origin — REST tombstone-backed, CRDT ciphertext-backed, folder cascade, attachment move) enqueued within the last 10 minutes whose `old_basename_hmac` matches the dangling edge's `target_basename_hmac`. If found, re-run that rename's walk NOW: same args verbatim, cursor reset, `"sweep" => true` (terminates without recursion), insert-time unique so concurrent repairs and the rename's own pending sweep collapse to one run.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-link-extract-fast-path/lib/engram/workers/extract_note_links.ex`
- Test: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-link-extract-fast-path/test/engram/workers/extract_note_links_test.exs` (extend)

**Interfaces**
- Consumes: `Oban.Job` (args JSONB query, precedent: `EmbedNote.existing_burst_start/1`, `embed_note.ex:427-437`), `RewriteNoteLinks.new/2` per-call opts.
- Produces: telemetry `[:engram, :links, :repair_enqueued]` `%{count: 1}` / `%{origin: :extract}` — the datum Task 5's sweep re-evaluation needs.

**Steps**

- [ ] Extend the worker test file (helpers `seed_rename!`-style, mirroring `test/engram/workers/rewrite_note_links_test.exs:19-58`):

```elixir
  describe "bind-time rename repair (lever 2)" do
    import Ecto.Query

    defp clear_jobs!(worker) do
      Repo.delete_all(from(j in Oban.Job, where: j.worker == ^worker))
    end

    test "late dangling edge re-enqueues the rename's rewrite as an immediate sweep",
         %{user: user, vault: vault} do
      {:ok, _note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      {:ok, renamed} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
      # The rename's own chain "already ran": leave its job ROW (the repair
      # evidence) but no pending sweep, simulating rename+60s having passed.
      [rename_job] = all_enqueued(worker: Engram.Workers.RewriteNoteLinks)
      clear_jobs!("Engram.Workers.RewriteNoteLinks")
      {:ok, _} = Oban.insert(Engram.Workers.RewriteNoteLinks.new(rename_job.args))
      # Park the evidence row out of available state so drain-style helpers
      # can't run it; the repair query matches any state within the window.
      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      # Offline device's note arrives NOW, still referencing the old name.
      {:ok, late} = Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"})
      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})

      assert [repair] =
               all_enqueued(worker: Engram.Workers.RewriteNoteLinks)

      assert repair.args["sweep"] == true
      assert repair.args["cursor"] == "00000000-0000-0000-0000-000000000000"
      assert repair.args["target_id"] == renamed.id
      assert repair.args["old_basename_hmac"] == rename_job.args["old_basename_hmac"]
    end

    test "repair converges: performing the repair rewrites the source and a re-extract enqueues nothing (loop-breaker)",
         %{user: user, vault: vault} do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      {:ok, _renamed} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
      [rename_job] = all_enqueued(worker: Engram.Workers.RewriteNoteLinks)
      clear_jobs!("Engram.Workers.RewriteNoteLinks")
      {:ok, _} = Oban.insert(Engram.Workers.RewriteNoteLinks.new(rename_job.args))
      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      {:ok, late} = Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"})
      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})
      [repair] = all_enqueued(worker: Engram.Workers.RewriteNoteLinks)

      # Run the repair chain: the source note's text gets rewritten [[Old]]→[[Fresh]].
      assert :ok = perform_job(Engram.Workers.RewriteNoteLinks, repair.args)
      clear_jobs!("Engram.Workers.RewriteNoteLinks")

      # Re-extraction (as the rewrite's own persistence hooks would trigger):
      # edges now carry the NEW basename hmac → no prior-job match → NO repair.
      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})
      assert [] == all_enqueued(worker: Engram.Workers.RewriteNoteLinks)
      assert [%{dangling: false}] = Links.links_for_note(user, late.id)
    end

    test "repair dedups against the rename's still-pending sweep",
         %{user: user, vault: vault} do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      {:ok, _} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
      # Keep the rename's enqueued job AS the pending work (scheduled/available).
      assert [_pending] = all_enqueued(worker: Engram.Workers.RewriteNoteLinks)

      {:ok, late} = Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"})
      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})

      # Still exactly one job: the repair insert deduped via unique keys
      # [target_id, old_basename_hmac] over available/scheduled.
      assert [_only] = all_enqueued(worker: Engram.Workers.RewriteNoteLinks)
    end

    test "dangling edge with NO recent rename enqueues nothing",
         %{user: user, vault: vault} do
      {:ok, late} = Notes.upsert_note(user, vault, %{"path" => "L.md", "content" => "see [[NeverExisted]]"})
      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})
      assert [] == all_enqueued(worker: Engram.Workers.RewriteNoteLinks)
    end

    test "CRDT-origin rename (ciphertext args, no tombstone) is repairable — args ride verbatim",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md", origin: "web")
      [crdt_job] = all_enqueued(worker: Engram.Workers.RewriteNoteLinks)
      assert Map.has_key?(crdt_job.args, "old_path_ciphertext")
      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      {:ok, late} = Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"})
      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})

      assert [repair] = all_enqueued(worker: Engram.Workers.RewriteNoteLinks)
      assert repair.args["old_path_ciphertext"] == crdt_job.args["old_path_ciphertext"]
      assert repair.args["sweep"] == true
    end
  end
```

  (Executor note: `all_enqueued/1` in Oban's `:manual` testing mode returns jobs in `available`/`scheduled` states only — after the `Repo.update_all` to `"completed"` the evidence row is invisible to it, which is exactly what the assertions rely on. If a helper name differs — e.g. the factory for a completed job — keep the mechanism: a real args-bearing `oban_jobs` row in a non-pending state.)

- [ ] Run — the first test fails (no repair logic exists).
- [ ] Implement in `lib/engram/workers/extract_note_links.ex` — add `import Ecto.Query`, `alias Engram.Links.NoteLink`, `alias Engram.Workers.RewriteNoteLinks`, module attributes, and call the repair after a successful `replace_links` in `extract/1`:

```elixir
  @repair_window_seconds 600
  @start_cursor "00000000-0000-0000-0000-000000000000"

  # ... in extract/1, the success branch becomes:
          {:ok, decrypted} ->
            :ok = Links.replace_links(user, vault, note.id, Parser.extract(decrypted.content || ""))
            :ok = repair_rename_danglers(user, vault, note.id)
            :ok
```

  and the repair itself:

```elixir
  # #648 lever 2 — bind-time rename repair. A freshly-extracted edge that
  # lands DANGLING may be explained by a recent rename: the referrer's edge
  # simply didn't exist when RewriteNoteLinks walked (and, for arrivals later
  # than rename+60s, when its sweep re-walked). The durable evidence for
  # every rewriting rename origin (REST tombstone-backed, CRDT
  # ciphertext-backed, folder cascade, attachment move) is the original
  # oban_jobs row — retained 7 days by the Pruner, args already in the exact
  # T3.2 shape (ids + b64 HMACs/ciphertext). Re-enqueue those args verbatim
  # with the cursor reset and "sweep" => true:
  #   * "sweep" => true makes the repair chain terminate WITHOUT enqueueing
  #     another sweep (RewriteNoteLinks.maybe_enqueue_sweep/1) — one walk.
  #   * insert-time unique on [target_id, old_basename_hmac] over
  #     available/scheduled collapses concurrent repairs AND defers to the
  #     rename's own still-pending sweep (identical work, already scheduled).
  #     Chain successors insert via plain new/1 and are unaffected — this is
  #     a single-shot entry, not the self-re-enqueueing cursor-chain case the
  #     worker's no-unique rule exists for.
  # Loop-safety: a repair rewrite changes content → re-extraction produces
  # edges under the NEW basename hmac → no window match → terminates. A no-op
  # rewrite persists nothing → no re-extraction → no re-trigger.
  # Plugin/Obsidian-origin renames never enqueued a rewrite (one-rewriter
  # invariant) → no evidence row → correctly never repaired here.
  defp repair_rename_danglers(user, vault, source_note_id) do
    dangling_hmacs =
      Repo.all(
        from(l in NoteLink,
          where:
            l.source_note_id == ^source_note_id and l.user_id == ^user.id and
              l.vault_id == ^vault.id and is_nil(l.target_note_id) and
              is_nil(l.target_attachment_id),
          distinct: true,
          select: l.target_basename_hmac
        ),
        skip_tenant_check: true
      )

    Enum.each(dangling_hmacs, fn hmac ->
      case recent_rename_job_args(user.id, vault.id, Base.encode64(hmac)) do
        nil -> :ok
        args -> enqueue_repair(args)
      end
    end)

    :ok
  end

  # Newest rewrite-job row (ANY state — completed included) inside the window
  # whose old_basename_hmac matches the dangler. oban_jobs is not a tenant
  # table; user/vault are filtered as args. JSONB ->> precedent:
  # EmbedNote.existing_burst_start/1.
  defp recent_rename_job_args(user_id, vault_id, hmac_b64) do
    cutoff = DateTime.add(DateTime.utc_now(), -@repair_window_seconds, :second)

    Repo.one(
      from(j in Oban.Job,
        where: j.worker == "Engram.Workers.RewriteNoteLinks",
        where: j.inserted_at > ^cutoff,
        where: fragment("? ->> 'old_basename_hmac' = ?", j.args, ^hmac_b64),
        where: fragment("? ->> 'user_id' = ?", j.args, ^to_string(user_id)),
        where: fragment("? ->> 'vault_id' = ?", j.args, ^to_string(vault_id)),
        order_by: [desc: j.inserted_at],
        limit: 1,
        select: j.args
      )
    )
  end

  defp enqueue_repair(args) do
    :telemetry.execute([:engram, :links, :repair_enqueued], %{count: 1}, %{origin: :extract})

    args
    |> Map.put("cursor", @start_cursor)
    |> Map.put("sweep", true)
    |> RewriteNoteLinks.new(
      unique: [
        period: @repair_window_seconds,
        keys: [:target_id, :old_basename_hmac],
        states: [:available, :scheduled]
      ]
    )
    |> Engram.Notes.Enqueue.enqueue("rewrite_note_links")
  end
```

- [ ] Run the full worker test file — all green, including Task 1's tests (the no-rename test proves the common case costs one indexed `note_links` query and nothing else).
- [ ] Run `mix test test/engram/workers/rewrite_note_links_test.exs` — the rewrite worker itself is UNCHANGED in this task; its suite must be untouched-green.
- [ ] `mix format`; commit: `feat: bind-time rename repair — dangling extraction re-runs the rename walk`.

---

### Task 5 — Sweep re-evaluation (decision recorded, constant unchanged)

Do NOT remove or shorten `@sweep_delay_seconds 60` (`rewrite_note_links.ex:73`) in this PR. Record the criteria for the follow-up instead.

**Files**
- Modify: `/home/open-claw/documents/code-projects/engram/.worktrees/feat-link-extract-fast-path/lib/engram/workers/rewrite_note_links.ex` (moduledoc only)

**Steps**

- [ ] Append to the `RewriteNoteLinks` moduledoc's sweep paragraph:

```
  With the #648 fast path (ExtractNoteLinks, ~2s extraction) and bind-time
  repair (repair_rename_danglers/3) the sweep is a residual backstop for the
  narrow gap where an edge extracts AFTER the walk but BEFORE its own repair
  check could see a matching rename job (clock-skew/queue-latency slivers)
  and for plugin-origin renames (never server-rewritten, so never repaired).
  Re-evaluate shortening/removing it once prod shows
  [:engram, :links, :repair_enqueued] absorbing the late-edge cases and the
  sweep's second walks planning zero edits (rewrite failed=0, sweeps no-op).
```

- [ ] `mix format`; commit: `docs: record sweep re-evaluation criteria post fast-path`.

---

## e2e Consideration (no e2e code in this PR)

The Obsidian e2e suite drives plugin-origin sync, which never triggers server rewrites (one-rewriter invariant) — the fast path only changes WHEN edges appear, not what any e2e asserts. `ExtractNoteLinks` reuses the settled worker patterns (fetch/discard/rotation-gate) covered by unit tests. If a browser e2e for rename-latency is ever wanted it belongs to `e2e-browser` as a follow-up. No plugin settings change → no paired e2e-conftest PR.

## Final Verification (before PR)

- [ ] Sequential gauntlet from the worktree root: `mix format` → `mix credo --strict` → `mix dialyzer` → full `mix test --warnings-as-errors`.
- [ ] `mix test test/engram/workers/no_plaintext_args_test.exs` explicitly.
- [ ] Confirm no `mix.exs` version diff and no migration files.
- [ ] PR body: name the two levers, the CRDT answer (job-row evidence, not tombstones), the sweep's retained-backstop status, and the `link_extract_delay_seconds` knob.

## Self-Review

- [ ] **Latency claim honest**: REST edge ≈ 2s (leading-edge job). CRDT edge ≈ eager-checkpoint 250ms-5s + 2s ≈ 2.5-7s. Both are bounded by content PERSISTENCE, which extraction cannot precede. Embeddings untouched (30s/300s constants unmodified, `EmbedNote`/`Indexing` diffs are zero).
- [ ] **No double-extraction races**: single shared `replace_links` serialized by `pg_advisory_xact_lock` (Task 2), one lock per txn taken first — no deadlock pairs; unique-index tripwire defused at the root for every caller.
- [ ] **Known traps honored**: `:no_chunks` — worker parses directly, `""` → `[]` → edges cleared (test pinned). CRDT genesis — content lands only via checkpoint, which is hooked. `:re` unicode — `Parser.extract/1` scrubs invalid UTF-8 itself (`parser.ex:22-23`); worker passes content verbatim. T3.2 — new args are `note_id` only; repair args copied verbatim from an existing compliant row. Oban unique-on-cursor-chain trap — repair unique is per-call, entry-only, `[:available, :scheduled]`; successors unaffected (stated in code comment + pinned by the chain still completing in the convergence test).
- [ ] **Loop-breaker explicit and tested**: `"sweep" => true` termination + new-hmac convergence + insert-time dedup, each with its own test.
- [ ] **Placeholder scan**: no `TODO`/`similar to`/ellipsis-in-code except the two marked `...unchanged...` context anchors inside an Edit-context block (Task 2) and executor notes that name the exact file to copy from.
- [ ] **No suppressions added.**

## Spec requirements I could not ground in real code (gaps + resolutions)

1. **"Edge exists within ~a second"** — the floor is content persistence: REST hits ~2s (the debounce), but CRDT content doesn't EXIST server-side until the checkpoint timer fires (250ms eager / 5s settle). Extraction cannot beat materialization without parsing the Y-doc projection inside the room process (`update_v1` hot path — rejected: per-batch, inside the room GenServer, the plan's own "likely too hot" call confirmed). **Resolution:** ~2s from persistence, ~2.5-7s from keystroke on CRDT; stated honestly in Self-Review.
2. **True concurrency test for the advisory lock** — the Ecto SQL sandbox funnels test queries through one owner connection, so two "concurrent" `replace_links` calls in a test can't actually contend; a real interleave test would be dishonest. **Resolution:** sequential-convergence pin + the lock reviewed as code; the unique-index violation it prevents remains covered by the index itself (violation ⇒ Oban retry ⇒ converge) as defense-in-depth.
3. **CRDT-origin rename repair** — the brief asked whether the renamed row is findable for tombstone-less renames. Direct answer: not via basename (the row already carries the NEW `basename_hmac`; nothing durable maps old→new basename except the job row). **Resolution:** the `oban_jobs` evidence row covers CRDT (ciphertext args ride verbatim, tested). Residual uncovered class: renames older than the 10-min window or (theoretical) pruned job rows (7-day retention makes this moot inside the window), and plugin-origin renames — both fall to the retained +60s sweep / next-rename self-heal, per the "partial event-driven coverage beats none" scoping in the brief.
4. **Repair deferring to a pending sweep can add up to 60s** — when the rename is <60s old, the dedup lets the already-scheduled sweep do the work instead of running immediately. **Resolution:** accepted; with lever 1 the edge usually exists BEFORE the sweep fires, so the sweep's walk catches it — the repair's unique-vs-immediate tradeoff only matters in the sub-60s window where a guaranteed catcher is already scheduled.
5. **Exact test-construction details** — the CRDT checkpoint-doc builder (Task 3) and the completed-job-row fixture mechanics (Task 4) are sketched from `crdt_checkpoint.ex` internals and Oban `:manual`-mode behavior; the executor must copy the precise idioms from the named existing test files if the sketches drift from current helpers. The behavior under test (enqueue presence/absence, args identity) is fully specified either way.
