# Context Doc: Invalid UTF-8 at Rest → JSON 500

_Last verified: 2026-06-24_

## Status
Fixed (PR #740, issues #727/#738). Egress is now scrubbed at boundaries. **Observability + backfill follow-up** adds a boundary-tagged scrub metric, a write-boundary warning, and the #739 backfill task (see "Observability & Backfill" below).

## What This Is
Note content is encrypted (AES-GCM) and stored as Postgres `bytea` ciphertext. `bytea` storage **bypasses Postgres's UTF-8 validation**, so invalid UTF-8 in note content/title/tags persists at rest undetected and then crashes `Jason.encode` at every JSON egress that reads note bytes.

## Symptom
- `search_notes` (MCP) returned HTTP **500** — looked like a "concurrency" issue but is actually **content-dependent**, not concurrency.
- Crashed `Phoenix.PubSub.Adapter` on `note_changed` Channel broadcasts.
- Prod Loki signature: `** (Jason.EncodeError) invalid byte 0xE2 in <<...>>` where the bytes decode to the search response markdown / note content.
- Example corruption: a multibyte char like `–` (U+2013 = `E2 80 93`) truncated to a lone `0xE2` lead byte.

## Root Cause
1. JSON-decoded **input** is always valid UTF-8, so corruption enters via a client write where the raw bytes are already invalid.
2. The bytes survive encryption **byte-for-byte** (AES-GCM is byte-transparent), and `bytea` storage does no validation — so they persist at rest.
3. On read, decryption yields the same invalid bytes, which crash `Jason.encode` at **four** JSON boundaries:
   - MCP search response
   - Web `/api/search`
   - REST `GET /api/notes/:path` and `/changes`
   - Sync Channel `note_changed` broadcast

## Fix Architecture (the reusable lesson)
**Scrub to valid UTF-8 (invalid bytes → U+FFFD) at BOUNDARIES**, with a `String.valid?` fast path so valid input is returned byte-identical (this keeps `content_hash` stable — no spurious re-encrypts / sync churn).

Three chokepoints cover all four JSON boundaries:

1. **WRITE** — `Engram.Notes.upsert_note` + `normalize_batch_entries` (batch path) scrub **before** hash/encrypt.
2. **READ** — a single scrub at the note-decrypt boundary `Crypto.maybe_decrypt_note_fields/2` covers `get_note` + REST note/`changes` + Channel broadcast **all at once**, because `decrypt_notes_batch` fans out through it.
3. **SEARCH** — `Engram.Search` scrubs result fields. Search chunk text comes from the **Qdrant-payload decrypt**, a separate code path that does NOT go through the note decrypt — so it needs its own scrub.

Shared helper: `Engram.Notes.Helpers.scrub_utf8/1`.

## Gotchas
- **Any NEW JSON-serialization site that reads note content/title/tags MUST come through one of these boundaries**, or it will 500 on legacy corrupt rows.
- The decrypt-boundary scrub (single point covering 3 of 4 boundaries) is why **per-serializer patching (whack-a-mole) was rejected in review** — too easy to miss a site.
- Search chunk text is a distinct decrypt path (Qdrant payload), not the note decrypt — don't assume the note-decrypt scrub covers it.
- The `String.valid?` fast path is load-bearing: without it, every read would rewrite valid bytes and could destabilize `content_hash`.

## File:Line Anchors
- `lib/engram/crypto.ex` — `maybe_decrypt_note_fields/2` (READ boundary; `decrypt_notes_batch` fans out through it)
- `lib/engram/notes.ex` — `upsert_note` + `normalize_batch_entries` (WRITE boundaries)
- `lib/engram/search.ex` — `scrub_result_utf8` (SEARCH boundary; Qdrant-payload decrypt path)
- `lib/engram/notes/helpers.ex` — `scrub_utf8/1` (pure) + `scrub_utf8/2` (boundary-instrumented)

## Observability & Backfill (follow-up to #740)
The original #740 fix was **silent** — `scrub_utf8` replaced bad bytes with no signal, trading a noisy 500 for invisible (lossy) data mutation. The follow-up makes recurrence detectable and cleans up legacy rows.

- **Boundary-tagged metric** — `scrub_utf8/2` takes a `boundary` (`:write | :read | :search`) and, on the scrub slow path, emits `[:engram, :notes, :utf8_scrub]` (`%{count: 1}`, `%{boundary:}`). Surfaced to Prometheus as `engram_prom_ex_notes_utf8_scrub_total{boundary}` via `Engram.PromEx.Notes`. **`boundary="write"` rising = new corruption entering at rest (a buggy client) — actionable.** `read`/`search` reflect legacy rows being read and drain to zero after the backfill.
- **Write-boundary warning** — the `:write` boundary also logs a `:data`-category warning (`reason="invalid_utf8_scrubbed"`); read/search stay counter-only to avoid log spam on every legacy read. (`:data` is a new log category in `Engram.Logger.Category`.)
- **Backfill** — `mix engram.utf8_audit` (read-only count) / `--fix` (re-saves each corrupt note through the write path → scrub + re-encrypt + re-embed). Logic in `Engram.Notes.Utf8Backfill.scan/1`; detection uses `Crypto.decrypt_note_fields_unscrubbed/2` (raw decrypt, so the read-scrub doesn't mask corruption). Operator-invoked only; never runs on deploy. Release: `bin/engram rpc 'Engram.Notes.Utf8Backfill.scan(fix: false) |> IO.inspect()'`.
- **Alert** — a Grafana alert on `increase(engram_prom_ex_notes_utf8_scrub_total{boundary="write"}[10m]) > 0` lives in engram-infra (separate repo; only fires once the metric exists in prod, i.e. after this ships via a `release-v*` tag).

## File:Line Anchors (extras)
- `lib/engram/notes/utf8_backfill.ex` — `Engram.Notes.Utf8Backfill` (#739 scan/fix)
- `lib/engram/prom_ex/notes.ex` — `Engram.PromEx.Notes` (scrub counter → /metrics)
- `lib/mix/tasks/engram.utf8_audit.ex` — operator CLI

## References
- PR #740 (fix)
- Issue #727 (fixed) — search 500
- Issue #738 (channel `note_changed`, fixed; now has a direct broadcast-payload regression test)
- Issue #739 (backfill — shipped as `mix engram.utf8_audit --fix`)
