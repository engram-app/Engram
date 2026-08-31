# Stranded Qdrant points: the rename → delete race

_Found 2026-08-31 auditing a 303-note import into prod._

**Symptom.** Qdrant holds more points for a vault than Postgres has `chunks`
rows. The extras carry a `path_hmac` that matches **no** `notes` row — not a
live one, not a soft-deleted one. Postgres looks perfectly clean; the drift is
only visible by diffing the two stores.

```
db chunks: 1160   qdrant points: 1162
in Qdrant but NOT in DB (orphans): 2
in DB but NOT in Qdrant (missing vectors): 0
```

## Why it happened

Every delete path filtered Qdrant on the note's **current** `path_hmac`. A
rename changes that value while the points still carry the old one:

1. Note indexed at path A → every point's payload has `path_hmac = A`.
2. Rename A→B. `notes.path_hmac` becomes B. `RepathNoteIndex` is enqueued with
   `old_path_hmac = A`, scheduled 3s out; `EmbedNote` debounces 30s, clamped to
   300s. For that whole window the points are tagged A and the row says B.
3. Delete lands inside the window. `delete_note_index_job/2` builds args from
   `note.path_hmac` — **B**. The Qdrant delete filters on B, matches nothing.
   The chunk rows are then dropped, which succeeds.
4. `RepathNoteIndex` (and the `EmbedNote` fallback) call
   `Notes.fetch_note_for_worker/1`, which returns
   `{:discard, "note … is soft-deleted"}`. Neither ever touches Qdrant again.

The A-tagged points are now unreachable: nothing names them and no future
filter can match them.

**Nothing collected them.** `OrphanSweep` reaps at *user* granularity — it
groups points by payload `user_id` and deletes those absent from `users`. For a
live user, note-level strays were invisible to every cleanup path in the system.

Corroborating signal in prod: `EmbedNote` jobs discarded with
`"note … is soft-deleted"` — the same race seen from the indexing side.

## The fix

**Delete by point id, not by hmac.** `chunks.qdrant_point_id` is the only
identifier that survives a rename. `Indexing.delete_points_for_note/1` reads
those ids and calls `Qdrant.delete_points/2` **before** the chunk rows are
dropped — once the rows are gone, nothing names the points. Wired into both
`delete_note_index/1` and `commit_index/1`.

The `delete_by_note/4` hmac filter stays alongside it. The two cover disjoint
failure modes: id-delete reaches points whose hmac drifted, filter-delete
reaches points whose rows were already lost.

**Point-level reaping in `OrphanSweep`.** A fourth pass scrolls every point id
and deletes the ones no `chunks.qdrant_point_id` names.

Two ordering rules make it safe:

- **Scroll Qdrant first, read the DB second.** Indexing inserts chunk rows and
  *then* upserts points, so anything the scroll sees already has its row
  committed by the time the read runs. The other order races.
- **Re-check candidates after a grace window** (`:orphan_sweep_point_grace_seconds`,
  default 60, `0` in test). A sweep can straddle an in-flight re-index, which
  deletes and re-inserts chunk rows rather than updating them; deleting a live
  point there would silently drop a note out of search until something
  re-embedded it.

## How to check a vault by hand

Read-only prod DB access via the bastion is in
`engram-infra/docs/context/prod-db-readonly-access.md`. Then:

```sql
-- authoritative chunk ids (RLS: SET app.current_tenant first)
select qdrant_point_id from chunks where vault_id = '<vault>';
```

```bash
# every point id Qdrant holds for the vault
curl -s -X POST -H "api-key: $KEY" -H 'Content-Type: application/json' \
  -d '{"limit":1000,"with_payload":false,"with_vector":false,
       "filter":{"must":[{"key":"vault_id","match":{"value":"<vault>"}}]}}' \
  "$QDRANT_URL/collections/engram_notes/points/scroll"
```

Diff the sets. Points in Qdrant but not in the DB are strays; anything in the
DB but not in Qdrant is the more serious direction — a note missing from
search — and points at the embed path, not this one.
