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
| Subtree | `Folders.descendant_ids/2,3`, `Folders.subtree_filter/2` (cycle-safe, depth 512, refuses past `Qdrant.max_ids/0` = 2048) |
| Sweep | `ReconcileNotePayloads` (selects `payload_version < version()`) |

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
