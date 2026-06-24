# Context Doc: Invalid UTF-8 at Rest → JSON 500

_Last verified: 2026-06-24_

## Status
Fixed (PR #740, issues #727/#738). Egress is now scrubbed at boundaries; existing corrupt rows still need a one-time backfill (#739, non-crash-critical).

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
- `lib/engram/notes/helpers.ex` — `scrub_utf8/1` (shared helper)

## References
- PR #740 (fix)
- Issue #727 (fixed) — search 500
- Issue #738 (channel `note_changed`, transitively fixed)
- Issue #739 (backfill of existing corrupt rows — non-crash-critical once egress scrubs)
