# Prod OOM crash-loop (release-v0.5.613) — incident handoff + fix plan

_Created 2026-07-02. Branch: `fix/crdt-oom-compaction`. Root cause PROVEN by live measurement 2026-07-03._

> **NOTE — two wrong theories, corrected by measurement (the lesson: measure before theorizing):**
> 1. First blamed unbounded CRDT/Yjs history → disproven (max `crdt_state` 18 KB).
> 2. Then blamed "~100 MB off-heap per concurrent Voyage HTTP request" → **also disproven**: 8 concurrent `Voyage.embed_texts` = flat 154 MB. The balloon was `prepare_index`'s *language-detection* step, not the HTTP call.

## TL;DR (proven)

`release-v0.5.613` (CRDT-default) put prod into an **OOM crash-loop** (ECS: `"OutOfMemoryError: container killed due to memory usage"`, exit 137, every ~2-3 min), **connection-independent** (zero clients — socket/channel joins flat at 0).

Root cause: the **Lingua language-detector NIF** (`LangDetect`, called per chunk during indexing) loads **~945 MB of full-accuracy Latin-script n-gram models off-heap** (a one-time, process-global load — invisible to `:erlang.memory`). On the **1024 MB** Fargate task that OOM-kills the engram container whenever indexing runs. A **~341-note vault sync** created an `EmbedNote` backlog; `ReconcileEmbeddings` re-enqueues it every 15 min → each boot re-triggers model loading → OOM → jobs orphan as `executing` → self-sustaining. (Embed concurrency only sets *how fast* the models load; it does not bound the ~945 MB, so an embed-concurrency cap alone does NOT fix it.)

Fix: `low_accuracy_mode: true` in `LangDetect` → trigram-only models → **~135 MB** (measured, ~7×). With that, embed concurrency stays at 5 (full throughput; peak ≈ 560 MB). See `docs/context/lingua-language-detection-memory.md`.

Trigger: a **~341-note vault sync** (`019ef66f-*` UUIDv7 batch) created a large `EmbedNote` backlog.

## Measured evidence (one-off eval tasks → S3, bypassing the broken log pipeline)

| Test | Setup | Peak RSS |
|---|---|---|
| parse + tokenize + sparse-encode, all 341 notes, sequential | pure Elixir | 130 MB |
| same, 3× concurrent | pure Elixir | 151 MB |
| Voyage embed, 15 requests **sequential** | real HTTPS | **flat 136 MB** (no growth → not a leak) |
| `Indexing.prepare_index` incl. Voyage embed, **8 notes concurrent** | concurrent HTTPS | **1045 MB** |

- At the 1045 MB peak, `erlang:memory total = 91 MB` — so **~950 MB is off-heap**, invisible to Erlang's accounting = the TLS/OpenSSL layer under `Req`→`Finch`.
- Memory scales with **HTTP concurrency**, not data volume or request count. ~100 MB per simultaneous connection (abnormally high — see fix #3).
- Data is tiny: 341 notes, biggest content 38 KB, all content 2.4 MB. `crdt_state` max 18 KB.
- ECS confirms container-level OOM (task = 512 CPU / **1024 MB**, 3 containers, no per-container limits; sidecars ~110 MB combined).

## What it is NOT (ruled out by measurement)
- ❌ CRDT/Yjs history bloat — 18 KB max.
- ❌ Parser / tokenizer / sparse encoder — flat 130-151 MB even concurrent.
- ❌ A giant note — biggest 38 KB.
- ❌ A leak — sequential embeds flat, GC releases.
- ❌ Sidecars / cluster / `:global` — happens single-node, zero clients.

## Root cause anchors (`backend/`)
- `lib/engram/embedders/voyage.ex:109` — `Req.post` per embed request.
- `mix.exs:102` — `{:req, "~> 0.5"}` with **no named Finch pool anywhere** (grep: no `Finch.start_link`, no `finch:` config) → Req uses its default Finch (up to 50 conns/host).
- `config/config.exs:65` — `queues: [embed: 5, ...]` — embed concurrency 5.
- `lib/engram/workers/reconcile_embeddings.ex` — cron every 15 min, re-enqueues up to 500 stale notes (`@batch_size 500`).
- `lib/engram/indexing.ex:36/56/68` — `index_note → prepare_index → embed_for_indexing`.

## Fix (proven-directed, TDD)
1. **Cap embed queue concurrency** `config/config.exs` embed `5 → 1` (or 2). Directly kills the mechanism: at 1-2 concurrent, RSS stays ~140-280 MB, far under 1024. **Highest-confidence, cheapest fix.**
2. **Bounded shared Finch pool for Req.** Start a named `Finch` (small `size`, e.g. 5-10) in the supervision tree; pass `finch: Engram.Finch` to `Req.post` in the Voyage (and Qdrant/Ollama) adapters. Caps concurrent connections regardless of caller fan-out.
3. **Investigate the ~100 MB/connection** — abnormal for TLS. Candidates: `Req`/`Finch`/`Mint` TLS buffer sizes, `:ssl` socket `recbuf`, cert-chain decode per handshake, response decompression. Own follow-up; #1 makes it non-urgent.
4. **Observability:** engram FireLens output is the `null` plugin → app logs barely reach Loki and the crash-moment scrape is always missed. Fix so a fatal event ships at least one line (before-OOM memory high-watermark telemetry, shorter flush interval).
5. **(Infra, separate)** give the task headroom (memory ↑ and/or per-container limits); make `desired_count` and any interim memory bump permanent in TF or they revert on next apply.

## Prod state during incident (for the record)
- Version 0.5.613, task-def rev :93 (sha-2d923ab). **NOT rolled back** — fix forward.
- `desired_count` set to 1 via break-glass (TF still says 2 — reverts on next apply; the cluster `:global` cascade only mattered at 2 nodes and is a separate concern, not the OOM cause).
- **Stabilized 2026-07-03** by parking the embed backlog: `notes.embed_retry_after = now()+30d` for all pending-embed notes (the app's own poison-cooldown → `ReconcileEmbeddings` skips them) + cancelling queued `embed` jobs. No embeds run → no OOM → prod boots clean. **Search on the synced notes is stale until un-parked** (step below).

## Rollout sequence
1. ✅ Park embeds (done — stabilizes prod, no release).
2. Ship fix #1 + #2 (TDD) → `release-v*` tag on the version-bump commit (image build is skipped if `mix.exs` version unchanged — tag the bump commit, not a trailing test-only commit).
3. **Un-park:** clear `embed_retry_after` (`SET embed_retry_after = NULL WHERE embed_retry_after > now()+29d`) → backlog drains under the capped concurrency → search current.
4. Fix #4 (observability) and #5 (infra headroom / TF) independently.

## Guardrails carried in
- Backend pre-push gates on format + credo + sobelow (not just compile).
- Migration linters run in CI, not pre-push. `fix/` branch prefix is CI-eligible.
- Bump `mix.exs` version ONCE when opening the PR, never on follow-ups.
- Worktree deps auto-hardlinked by post-checkout hook — don't re-run `deps.get`.
