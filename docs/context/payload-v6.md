# Payload v6: the folder row id on the points, in three releases

_Last verified: 2026-10-27 (release R-a, nothing rewritten yet)_

**What changes:** the point key `f` (direct folder) goes from the HMAC of the
folder's path to the folder's ROW id (`notes.folder_ref_id`, undashed uuid), so
a folder move or rename changes no payload and a subtree search is
`f any [descendant row ids]`, expanded at query time. Every other v5 key is
byte-identical. A note in the vault root has no folder row and no `f`.

## Pieces (all in R-a)

| Piece | Where |
|---|---|
| Stamp | `note_index_state.payload_version` (nullable; NULL = baseline 5) |
| Version constant | `Engram.Indexing.PayloadV6.version/0` (`@version`), baseline `baseline/0` |
| Builder from Postgres rows (note + `note_attrs` + `folder_ref_id`), extraction fallback | `Engram.Indexing.PayloadV6` |
| Reader, both forms | `Qdrant.match_filter(:folder, ...)`: HMAC, row id, or a mix, over the same `f` index |
| Subtree | `Folders.descendant_ids/2,3`, `Folders.subtree_filter/2` (each id once, cycle-safe to depth 512, `{:error, :folder_subtree_too_large}` past `Qdrant.max_ids/0` = 2048; `Search.input_error_message/1` has its text and `SearchController` renders it as 422, so the filter layer returns it as a refusal, never an empty result) |
| Sweep | `ReconcileNotePayloads` (selects `payload_version < version()`; merges the new payload and deletes keys it dropped, in one `set_payloads` batch per page, then verifies both on read-back) |

The rows path trusts `note_attrs` only when the note's last index pass finished
on its current text (`PayloadV6.fresh?/1`: `embed_hash == content_hash`, which an
edit clears); otherwise, or with no rows, the caller's extraction answers (it
decrypts the body). Tested through Postgres with rows written by the app's own
pass (`payload_v6_db_parity_test.exs`).

`fa` is sorted in `PayloadV6.build/2`, so the rows path and the extraction path
agree (extraction order is not row order). The v5 builder is untouched, so no
payload hash changes in R-a.

## Rollout order (reader first)

1. **R-a (this release):** the reader accepts both forms of `f`, the column,
   the builder (not wired), the sweep selection extended with
   `version == baseline` (selects nothing). The points are still v5.
2. **R-b:** one release that (a) sets `@version` to 6, (b) points writers and
   the sweep at `PayloadV6` (the single seam is
   `Indexing.expected_v5_payload/2`, which `ReconcileNotePayloads` also calls),
   (c) stamps `payload_version` in the index pass. The sweep then rewrites every
   note ONCE, with zero Voyage calls, paced by the existing worker limits (200
   notes, 200 ms pause, `crdt_backfill` lane). Before it ships: the `f` index
   already exists (uuid); any NEW key needs its index created first
   (`qdrant-strict-mode-unindexed-filter.md`).
3. **R-c (weeks later):** drop `p` only if a grep proves no reader, drop
   `folder_hmac`, remove the legacy filter code.

## Rollback rule

- R-b to R-a code: stamps are `<`-compared, so a stamp of 6 is current for
  version 5; nothing is rebuilt. Points hold `f` as a row id; R-a's reader
  matches both forms, so folder filters keep working. Do not lower `@version`
  and re-bump to "redo" a sweep: bump to the next number.
- Below R-a (the previous release): its folder filter matches only HMACs and
  returns nothing for an `f` that is a row id until that note is re-indexed.
  That is why the reader ships a release BEFORE the writer flip. Never skip R-a.
- Never repair by `PUT /points/payload` or by upserting (the 2026-10-26 payload
  write slowdown; vectors are untouched by design).

## Caveats

- A row-id subtree search is only valid after the R-b sweep has rewritten `f`:
  before it, points carry the HMAC form and a row-id-only filter matches none of
  them (silently empty). R-a ships the reader; nothing calls it yet.
- A note still on legacy (v3) points is healed by the old hash path and is NOT
  stamped with a payload version, so it stays in the sweep's view (one cheap
  check per hour) until it is re-indexed to v5.
- `descendant_ids` caps the answer, not the walk: Postgres still visits the
  whole subtree (up to 512 levels) before the cap refuses. Fine at today's sizes.
- This chain does not contain fix 2261, so the hash-NULL heal (`heal_note`)
  still uses `overwrite_payload` (PUT) until the chain is rebased onto main. The
  version refresh never PUTs.
