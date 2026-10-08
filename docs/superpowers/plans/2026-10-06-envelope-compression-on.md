# Envelope compression on (R2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn on compress-then-encrypt for the large encrypted columns and new attachments, drop FinalizeRevision's own gzip, and re-encode existing rows through a self-healing data migration (release R2 of #1872).

**Architecture:** PR 2 shipped the engine and the policy (`Envelope.compression_policy/1`, keyed on the AAD's `table:column`) behind `config :engram, :envelope_compression` (default `false`). This PR sets it `true`, fixes the two places that infer plaintext size from ciphertext length, and adds `Engram.DataMigrations.EnvelopeFormat` on the PR 1 ledger: it re-encodes legacy (12-byte nonce) rows in the compressible DB columns, per user, under the row's own DEK and AAD, with a compare-and-set on the old ciphertext.

**Tech Stack:** Elixir, Oban, Postgres; the PR 1 ledger (`Engram.DataMigration`, `DataMigrations.any_row?/1`, `jobs_in_flight?/1`); the PR 2 engine.

**Spec:** Engram vault `50 Engineering/_Superpowers Specs/2026-10-06-envelope-engine-and-data-migrations-design.md`, sections 4.3, 6, 7 (R2), 8, 10.

## Preconditions (check before starting; stop and report if false)

- PR 1 (#1888, data-migrations ledger) is merged.
- PR 2 (envelope engine) is merged AND released to prod (a `release-v*` tag containing it is live on every node). R2 writes format 1; every node must already read it.

## Global Constraints

- Branch off main after both preconditions hold: `feat/1872-envelope-compression-on`, worktree under `.worktrees/`. Isolated test DB partition.
- Every mix command via `mise exec --`. Commits signed, conventional, with the session trailer lines. No em dashes.
- Compressible columns (DB): `notes.content_ciphertext`, `notes.crdt_state_ciphertext`, `crdt_update_log.update_ciphertext` (shares the `notes:crdt_state:` AAD), `vault_index_states.state_ciphertext`, `vault_index_update_log.update_ciphertext`. `note_revisions.pending_*` is a verbatim copy of `notes.content` and inherits its format; it is NOT re-encoded separately.
- Attachments: new uploads use `:auto` (policy). Existing attachment blobs are NOT re-encoded: format 0 raw and format 1 raw cost the same bytes, and re-uploading every media blob to flip a format byte buys nothing.
- Empty plaintext is always format 0 (engine rule). A 16-byte ciphertext (tag only) is a legitimate final state, never "legacy work".
- The backfill never overwrites a row that changed since it was read (CAS on the old ciphertext), never runs for a user mid-DEK-rotation (`Engram.Crypto.RotationLock` / `RotationGate`), and re-encodes under the row's CURRENT DEK version and AAD (no DEK change).
- Done predicate = exactly the rows the worker would re-encode (the ledger rule in `docs/context/data-migrations-ledger.md`).

## Review Focus

1. A note edited between the backfill's read and write must keep the edit (CAS miss = skip, picked up next pass). Pinned in Task 3.
2. A user whose DEK rotation starts mid-pass must not get rows written under the old DEK version. Pinned in Task 3.
3. `CrdtBloatSweep` and `Revisions.has_content?/1` must stay correct on a mix of format 0 and format 1 rows. Pinned in Task 2.
4. A row that cannot be decrypted keeps the migration open (stuck alert), never crashes the batch. Pinned in Task 3.
5. Rolling back to PR 2's release after R2 rows exist must still read them (PR 2 reads format 1): verified in Task 1 by a test that opens a policy-on row with the policy off.

---

### Task 1: Policy on

- Set `config :engram, :envelope_compression, true` in `config/config.exs` (all envs); keep the key so an operator could, in an emergency, turn writes back to format 0 without a release.
- Tests: with the default config, a new note's `content_nonce` is 13 bytes, title nonce 12; the same row decrypts after `Application.put_env(:engram, :envelope_compression, false)` (rollback read); an attachment upload of 200 KB random bytes stores format 1 raw (ct = plain + 1 + 16) and of 200 KB markdown stores format 1 zstd (smaller).
- Commit `feat(crypto): compress-then-encrypt for large columns`.

### Task 2: Code that infers plaintext size from ciphertext length

- `Engram.Workers.CrdtBloatSweep` (`lib/engram/workers/crdt_bloat_sweep.ex` ~190, 215-219) computes plaintext size as `octet_length(col) - tag_bytes()`. With compression that is stored size, not text size. Ruling: the gauges now report STORED bytes (what the page cache actually holds); rename the metric descriptions/doc text to say "stored", keep metric names (dashboards), and note in `docs/context` that the crdt/content ratio is meaningful once both columns share a format (after the backfill). Update its tests: a format-1 row's sized bytes equal its stored ciphertext minus tag.
- `Engram.Notes.Revisions.has_content?/1` (`revisions.ex` ~244, `byte_size(ct) > tag_bytes()`): stays correct because empty plaintext is always format 0. Add a test: an empty note written with the policy on has a 16-byte content ciphertext and `has_content?` is false; a 1-char note is true.
- `FinalizeRevision` (`lib/engram/workers/finalize_revision.ex` ~107-135): drop `:zlib.gzip`; the blob's AAD (`note_revisions:content:`) is in the policy, so `Envelope.encrypt/3` compresses it. No reader of revision blobs exists yet (#1711 builds one), and prod recording is off, so no old gzip blobs need reading; state that in the moduledoc and in the #1711 issue as a comment.
- Commit `fix(crypto): size math and revision blobs under compression`.

### Task 3: `EnvelopeFormat` self-healing re-encode

**Files:** `lib/engram/data_migrations/envelope_format.ex` (the `Engram.DataMigration`), `lib/engram/workers/reencode_envelopes.ex` (per-user worker), tests for both, registration in `DataMigrationsRunner.@migrations`, a row in `docs/context/data-migrations-ledger.md`.

- `EnvelopeFormat`: `name/0` = `"envelope_format"`, `version/0` = `1` (bump when a new format ships). `run_pass/0`: `jobs_in_flight?(ReencodeEnvelopes)` -> `:more`; else enqueue one job per user who has legacy rows (`TenantScan` per user, the predicate below), `:done` when none.
- Legacy-row predicate, per table: `octet_length(nonce_col) = 12 AND octet_length(ct_col) > 16` (16 = tag only = empty plaintext, legitimately format 0), plus each table's liveness filter the worker uses (notes: `deleted_at IS NULL`; skip notes in soft-deleted vaults only if the worker skips them).
- `ReencodeEnvelopes` (queue `crypto_backfill`, `priority: 3` so DEK rotations go first, `max_attempts: 5`, finite `timeout/1`): for one user, `RotationGate`-check first (snooze if rotating); then per table in batches of 200 by id cursor: read row, `Envelope.decrypt` with its AAD and current DEK version, `Envelope.encrypt` with the same AAD (policy picks the mode), `UPDATE ... SET ct = new, nonce = new WHERE id = ^id AND ct = ^old_ct` (CAS). A decrypt failure: log at `:warning` with table and row id, leave the row (it keeps the migration open; the stuck alert surfaces it). Re-check the rotation gate between tables.
- Do NOT touch `crdt_head` semantics by accident: a `notes.crdt_state_ciphertext` rewrite fires the `notes_crdt_head_invalidate` trigger and NULLs the head; WarmCrdtHeads re-warms it within the hour. Note it in the moduledoc; it is acceptable once per note.
- Tests: legacy rows in each table get 13-byte nonces and decrypt to the same plaintext; an empty note stays 16 bytes and does not count as work; a row changed between read and write is not overwritten (seam: call the per-row write with a stale `old_ct`); a user mid-rotation is snoozed with no writes; an undecryptable row is logged, left, and the pass returns `:more`; `run_pass` is `:done` when only empty/format-1 rows remain; the #1349 tenant-scan list in `test/engram/backfill/tenant_scan_test.exs` gains the discovery function.
- Commit `feat(data-migrations): re-encode legacy envelopes`.

### Task 4: Docs, measurement, gates

- `docs/context/encryption-operations.md`: R2 is live; the rollback story (PR 2 release reads format 1; the config key turns writes back to format 0); the length side-channel caveat from the spec (section 10) verbatim in substance.
- After deploy (in the PR body, not code): `SELECT * FROM data_migrations WHERE name = 'envelope_format'`, and a read-only prod measurement of total stored bytes for the five columns before and after (the 1k-user page-cache argument from #1872).
- Gates: format, credo --strict, compile --warnings-as-errors, sobelow, dialyzer, full suite once alone.
