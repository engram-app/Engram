# Immutable chunk index: Qdrant side, in place (implementation plan)

_Revised 2026-11-05 against origin/main 7721e6860. Plan only: no code, no PR._

Scope set by Todd (2026-11-05): no second cluster, no second collection, no custom
sharding. The current cluster (mx1: 0.5 vCPU, 4 GiB RAM, 16 GiB disk) and the current
collection stay. Points gain one key, `n` (note row uuid). Writers stop copying note
metadata onto points. The old keys stay on old points, unused, and their indexes are
dropped at contract.

Design: Engram vault `50 Engineering/_Superpowers Specs/2026-11-05-immutable-chunk-index-design.md`.
Root cause: Engram#2263. The Postgres resolver is sql-lane's (`feat/pg-filter-resolver`),
contract `{:ids, [note_uuid]} | {:exclude, [note_uuid]} | :too_wide`, user + vault scoped.
Called `NoteFilter.resolve/3,4` below; the real name is sql-lane's. Line numbers are
origin/main 7721e6860.

## 0. Facts this plan rests on

| # | Fact | Evidence |
|---|---|---|
| F1 | Prod Qdrant 2026-11-05: 902,160 points; real disk 38% of 16 GiB (~6.5 GB; the gate's own reading); heap 16%; strict-mode disk limit 93%; 17 segments; `/memory` file sum 7.73 GB (overstates). | Grafana `engram_prom_ex_qdrant_{points,pressure_percent,strict_limit_percent,segments,disk_bytes}` |
| F2 | Every payload write copies the whole point (vectors included) into a new segment; the old copy is dead until the vacuum optimizer rewrites its segment, which happens only past `deleted_threshold` (default 0.2) per segment. | `docs/context/index-version-self-heal.md` "Rollout trap: the in-place rewrite makes disk PEAK" and "The disk gate can stall the pass for good"; `qdrant_layout.ex:263-264` |
| F3 | `Rebuild.qdrant_pace/1` snoozes a job while disk >= min(`:rebuild_max_disk_percent` 75, strict limit - 5), the update queue > 100, or > 50,000 points await optimization / collection not green. Snooze 30 s doubling to 600 s. | `rebuild.ex:110,432-438,446-460,567-605` |
| F4 | Point ids are deterministic `uuid5(note_id, context_hmac, ordinal)`; chunk rows name them. | `indexing/point_id.ex:16-19`, `indexing.ex:3815` |
| F5 | The 517k/day payload rewrites come from one place: `commit_index` re-PATCHes every reused point when `payload_hash` moves (`indexing.ex:1115,1146`), and `up` falls back to mtime so every edit moves it (`payload_v5.ex:77-84`). | Engram#2263 comments |
| F6 | Sparse is never re-encoded on a plain edit: reused points keep their vectors. Re-encodes happen only on a keyword version bump, a rename (`repath_note_index.ex:98`) or a DEK rotation. | `indexing.ex:3205-3260`, `refresh_keyword_vectors.ex` moduledoc |
| F7 | #2201 (word pairs) already shipped as keyword v5 + `Search.PhraseCheck`; the issue is still open. | `keyword_index.ex:62-69`, `search/phrase_check.ex` |
| F8 | Id lists already chunk at `@max_ids 2048`; strict `condition_max_size` 4096, `filter_max_conditions` 64. | `qdrant.ex:45`, `qdrant_layout.ex:124-135` |
| F9 | The payload sweep exists: `ReconcileNotePayloads` selects `coalesce(payload_version, 5) < PayloadV6.version()` (`reconcile_note_payloads.ex:171-181`), 200 notes per hop, 256 ops per `set_payloads` request, 200 ms pause, single-slot `crdt_backfill` lane (`:56,79-87`), driven by the `NotePayloadStamps` data migration whose version follows `PayloadV6.version/0` (`data_migrations/note_payload_stamps.ex:31`). It is NOT paced by `qdrant_pace` today. `PayloadV6 @version 5` (`payload_v6.ex:37-42`). |

**Sparse / avgdl: not needed to stop rewrites.** Per F6, avgdl drift never rewrites a
stored point; only new chunks pick up the current value. Fixed avgdl is dropped from
this plan. Close #2201 as done (F7). Renames still re-encode sparse because the
encoded `context_text` holds folder and title (`indexing.ex:3517-3522`): ~3,113
`update_vectors`/day, accepted, removed only by the design's separate "name point"
change.

## 1. Writers put `n` on every point

- `PayloadKeys` (`payload_keys.ex:11-32`): add `note_id: "n"`. `index_fields/0`
  (`:93-110`) gains `{"n", @uuid}`. `QdrantLayout.payload_indexes/2`
  (`qdrant_layout.ex:285-321`) gives it `enable_hnsw: false` on >= 1.19.2 like every
  non-tenant field.
- Index creation is automatic and boot-time: `ensure_payload_indexes/3`
  (`qdrant.ex:368-388`) creates any listed field the collection lacks, with
  `wait=true` on the last one. Ships in R1, so the index exists before any writer
  stores `n` and before any reader filters on it (strict mode 400s an unindexed filter).
  Cost on 902k points that have no `n` yet: a scan that finds nothing; trivial.
- `PayloadV5.build/2` (`payload_v5.ex:30-60`): emit `n` = `FilterId.uuid(note.id)`.
  This moves every note's `payload_hash`, so each note's next index pass re-PATCHes its
  reused points with `n` (the existing refresh). That is a free partial backfill for
  active notes, not extra load: those notes are re-PATCHed on every edit today anyway.
- Upserts (`build_entry/3`, `indexing.ex:3662-3693`) carry the payload, so new points
  get `n` from the same build.

## 2. Backfill `n` onto existing points (one paced sweep)

**Mechanism (reuse, no new worker).**

- Bump `PayloadV6 @version` to 6, meaning "points carry `n`". This reopens the
  `NotePayloadStamps` ledger (version 2) and the sweep selects every note with
  `payload_version < 6`. The parked folder-row-id meaning of v6 (`payload-v6.md` R-b)
  is retired; update that doc.
- New branch in `ReconcileNotePayloads` for version 6: per note, read its point ids from
  chunk rows (`Indexing.point_ids_for_note/1`, `indexing.ex:1809`), send
  `set_payloads` ops `{points: ids, payload: %{"n" => note_id}}` (a MERGE: no
  `overwrite_payload`, no key deleted), stamp `payload_version = 6`. No DEK, no
  decrypt, no `expected_v5_payload/2` (the expensive part of today's branch). Points
  that already hold `n` (refreshed by an edit since R2) are filtered out by a
  `must_not: is_empty n` scroll per page, so they are not rewritten twice.
- Pacing: call `Rebuild.qdrant_pace/1` before each page (today the worker only sleeps
  200 ms). A gated job snoozes with `Rebuild.gate_snooze/1`. Keep the single-slot
  `crdt_backfill` lane, so at most one page (<= 256 points) is in flight fleet-wide.
- In-pass stamp: `commit_index` stamps `payload_version = 6` when it stamps
  `payload_hash` (`indexing.ex:1177`): a hash that includes `n` proves every point
  holds `n`.
- **Done** = the `NotePayloadStamps` pass finds no note below 6 AND one Qdrant
  `POST /points/count {filter: is_empty n, exact: true}` returns 0 points that belong to
  a live chunk row. A node from the previous release can still upsert a point without
  `n` during a rolling deploy after the note was stamped; the count catches it. Points
  without `n` and without a chunk row are orphans: OrphanSweep reaps them, the done
  check ignores them (they never match an `n` filter anyway).

**Disk math (prod numbers, F1).** Capacity 16 GiB = 17.18 GB. Used now 38% (~6.5 GB,
~7.2 KB per point all in).

| Term | Value | Percent of capacity |
|---|---|---|
| Disk now | 6.5 GB | 38.0 |
| Dead copies before any segment vacuums: the sweep walks notes by id, so copies spread evenly; no segment passes `deleted_threshold` 0.2 until ~20% of the corpus is rewritten: 0.2 x 6.5 GB | 1.3 GB | 7.6 |
| One segment's optimizer copy: `max_segment_size` 128,000 KB of vector storage, ~64k points x 7.2 KB | 0.46 GB | 2.7 |
| New `n` bytes (~45 B x 902k) + `n` index (~40 B x 902k) | ~0.08 GB | 0.5 |
| **Expected peak** (the self-heal doc's formula) | **~8.3 GB** | **~49** |
| Gate (`qdrant_pace`): min(75, 93 - 5) | | **75** |

- One-time rewrites: at most 902,160 point copies (fewer: notes edited after R2 get `n`
  through their own refresh). For scale, today's refresh already rewrites 412k-980k
  points a day (Engram#2263), so this is about one to two days of today's churn, once.
- **Disk ceiling: 75% (the existing gate), ~26 points above the expected peak.** The
  worst case, if no segment ever vacuumed, is 38 + 38 = 76%: the gate stops the sweep at
  75% before that, and the stall trap cannot happen here because the 20% threshold is
  crossed at ~45-46%, far below 75.
- **Pace limit:** one page (<= 256 points) in flight fleet-wide, a `qdrant_pace` check
  before every page, 200 ms between pages, and the optimizer gate (<= 50,000 points
  queued, update queue <= 100). Ceiling: <= 256 points per 200 ms + request time, about
  1,000 points/s at most; in practice the optimizer gate sets the rate on 0.5 vCPU.
  Add a runtime cap `:payload_backfill_points_per_min` (default 1,000: 902k points in
  ~15 h; today's refresh averages ~360 points/min, so the sweep adds ~2.8x that rate for
  under a day) and the existing
  kill switch pattern (`:keyword_refresh`-style override, `payload_backfill`) so prod
  can stop it without a deploy.
- Watch: `rebuild_gated_total{reason}`, `engram_prom_ex_qdrant_pressure_percent{kind="disk"}`
  rising then falling, segments, and search p95 (the slowest 5% of searches) while the
  optimizer works. A flat disk line with sustained `reason="disk"` is the stall.

## 3. Search reader

In `lib/engram/search.ex` and `lib/engram/vector/qdrant.ex`. The `n` path is used only
once the `NotePayloadStamps` v2 ledger row is done (`VectorLayout.n_ready?/0`, cached
30 s like `IndexVersions.newest_completed/1`). Before that, the current filters run
unchanged.

- **Resolve** filters once per request with `NoteFilter.resolve(user, vault, filters)`,
  replacing `translate_phase_b_filters/4` (`search.ex:812-860`),
  `resolve_field_filters/2` (`:108-121`) and the date bounds when `n_ready?`. No filters:
  no call.
- **Shapes** (new `Qdrant.note_scope_filter/2`, next to `build_tenant_filter/1`,
  `qdrant.ex:1919`):
  - `{:ids, ids}`: `must: [u, v | v any], should: [n any block]...` with blocks from
    `Enum.chunk_every(ids, Qdrant.max_ids())`; at most 5 blocks: cap
    `Qdrant.max_note_ids/0 = 5 * max_ids() = 10_240`. Empty list: return `{:ok, []}`,
    no request. Wrap the should list in one nested `%{should: ...}` inside `must` so it
    ANDs with `u`/`v`.
  - `{:exclude, ids}`: `must: [u, v], must_not: [n any block]...`.
  - `:too_wide`: `must: [u, v]` only, fetch `limit x 4`; after `postgres_hits/2`
    (`search.ex:911`, which maps each point to its note via chunk rows), keep hits in
    `NoteFilter.resolve(user, vault, filters, within: candidate_note_ids)` (always under
    the cap, returns `{:ids, kept}`). Short of `limit` with a full page: double the
    fetch, at most 2 more rounds, never above strict `max_query_limit` 8192.
  - Cross-vault grants (`put_vault_filter/3`, `search.ex:883`): resolve per vault and
    union; past the cap, `:too_wide`.
- Grouping keeps the current client-side `collapse_to_notes/1` (`search.ex:1102`); hits
  can now carry `n` (`with_payload: ["n"]`) instead of the note lookup, optional.
- **Fallback before `n_ready?` on a release with the old filter code deleted** (R3 on an
  install that skipped R2): every filtered search takes the `:too_wide` path. Correct,
  lower recall for narrow filters on big vaults, until the sweep finishes.

## 4. Stop writing note metadata

Gated on the same `n_ready?` flag, in R2, so a rolling deploy never mixes "reads use old
keys" with "writes stopped". After the flag:

- `build_prepared/5` (`indexing.ex:3513-3514`): payload is `%{"u", "v", "n"}`, built
  without `FlatFields`; `FlatFields.extract` still runs for `note_attrs`
  (`stamp_flat_fields/1`, `:3858`), which the resolver reads.
- `commit_index/2` (`:1098-1210`): no refresh. `refresh_ids` (`:1115`) is `[]`, no
  `refresh_payload` (`:1146`); `payload_hash` stamping (`:1177`) and the superseded
  unstamp (`:1188-1191`) become no-ops. Reused points get zero Qdrant calls.
- `RepathNoteIndex` (`repath_note_index.ex:89-98`): skip `repath_points/2`
  (`indexing.ex:1717`, a `set_payload_by_filter` on `p`/`f`); keep the
  `RefreshKeywordVectors` kick (sparse holds the path, section 0).
- `ReconcileNotePayloads` drift heal (NULL `payload_hash`, DEK rotation) stops: `u`, `v`,
  `n` never change and are not HMACs. `UserDekRotation` (`user_dek_rotation.ex:2534-2537`)
  keeps clearing `keyword_version` (sparse is HMAC-keyed) and stops queueing the payload
  heal.
- Note delete: filter delete `u = user AND n = note` replaces the `path_hmac` filter
  (`delete_points_by_filter/1`, `indexing.ex:1780`); by-id delete stays as the belt.
- Old points keep their old keys forever (until edited), unused.

Expected effect: payload rewrites go from 412k-980k/day to 0; Qdrant point writes
become ~30k/day of new content (`indexing_points_written_total`).

## 5. Contract: drop old-key indexes

- Remove from `PayloadKeys.index_fields/0` every key but `u`, `v`, `n` (17 indexes:
  `p f y g s a r o j up cr rd ex du pr` plus `fa[].k/h/n/d`; and the legacy names if
  `:legacy_filter_fields` is on somewhere, `qdrant_layout.ex:93-100`). Same release:
  a data migration `DropOldPayloadIndexes` (runs only after `n_ready?`) sends
  `DELETE /collections/{c}/index/{field}` for each, idempotent (404 = done). Removing
  them from the list in the SAME release stops boot from re-creating them.
- Gain: prod measured ~1.9 KB of payload index per point (`index-version-self-heal.md`
  "Measuring disk"), so up to ~1.7 GB (~10 points of disk) minus the `u`/`v`/`n` share,
  plus their mmap pages and id maps. Not verified on today's 902k: measure
  `/collections/{c}/memory` before and after on prod (staging's per-point index cost is
  ~6x prod's and does not predict it).
- **Deleting the old key bytes from points: not worth it.** They are roughly 0.3-0.5 KB
  per point (~0.3-0.45 GB, estimate, not measured), and deleting them is the same
  902k-copy rewrite as the backfill (~11 points of transient disk, a day or two of
  optimizer CPU on 0.5 vCPU). Edited notes shed them naturally (new points carry only
  `u`, `v`, `n`). Revisit only if payload storage shows up as a real cost.
- Delete code (all R3, contract phase):

| Item | Where |
|---|---|
| `PayloadV5`, `PayloadV6` and their tests | `indexing/payload_v5.ex`, `indexing/payload_v6.ex` |
| Payload refresh code in `Indexing` | `indexing.ex:1115,1146,1177,1188-1191,1245-1288,1717-1747,3733-3812,3838,3912` |
| `Qdrant.overwrite_payload`, `set_payload/3,4`, `delete_payload_keys`, `set_payload_by_filter`, `v5_repath_payload`, `delete_leaked_plaintext_keys`, `match_filter`/`legacy_match_filter`/`folder_filter`/`range_filter`/`attr_filter`, field parts of `build_tenant_filter`, `delete_by_note`/`count_by_note` (path filters), `fallback_payload` | `qdrant.ex:1134-1475,1504-1556,1752-1951,2060` |
| `ReconcileNotePayloads` except the `n` branch (kept for skipped-release installs), its drift heal, Drain `:payload` lane, `note_index_state_unstamped` usage | `workers/reconcile_note_payloads.ex`, `bookkeeping/drain.ex:115,164` |
| Search old filter code: `translate_phase_b_filters`, `resolve_field_filters`, `payload_fallback`; `FieldFilters` Qdrant output; `Folders.subtree_filter` | `search.ex:108,812,946`; `search/field_filters.ex:95-244`; `folders.ex:119` (coordinate with sql-lane) |
| DEK rotation legacy payload scroll + text re-encrypt, `RotationTextGuard` | `crypto/user_dek_rotation.ex:1867`, `workers/rotation_text_guard.ex` |
| `LEGACY_FILTER_FIELDS` / `:legacy_filter_fields`, legacy layout lists | `config/runtime.exs`, `qdrant_layout.ex:93-100,250-321` |
| `mix engram.strip_qdrant_plaintext` | `lib/mix/tasks/` |
| Columns `notes.payload_hash`, `note_index_state.payload_hash` + partial index `note_index_state_unstamped` (`payload_version` STAYS: it is the `n` stamp) | contract migration in R3+1, after R3 is live |

Not deleted: `FlatFields`/`note_attrs`, `RefreshKeywordVectors`, avgdl code, OrphanSweep.

## 6. Releases (one PR each, reader first)

Depends on sql-lane's resolver PR (incl. `within:`) merging first.

### PR 1 / R1: reader + `n` index

- `n` in `PayloadKeys` index list (boot creates the index); `note_scope_filter/2`,
  `max_note_ids/0`, the `:too_wide` post-filter, `n_ready?/0` (false until R2's ledger
  exists, so R1 behaves exactly like today).
- Red on main, green with the PR:
  - `test/engram/vector/qdrant_note_scope_filter_test.exs`: 5,000 ids gives 3 blocks
    <= 2048 inside one nested should; 10,240 gives 5; 10,241 refused; `{:exclude}` gives
    `must_not`; empty ids sends no request.
  - `qdrant_collection_test.exs`: an existing collection without `n` gets
    `PUT /index {field_name: "n", field_schema: uuid}`.
  - `qdrant_strict_callers_test.exs`: pins `max_note_ids <= filter_max_conditions x max_ids`
    and block size `<= condition_max_size / 2`.
  - `search_note_filter_test.exs` (Bypass + stub resolver): with `n_ready?` true, `{:ids}`
    sends `n any`; `:too_wide` sends only `u`+`v` at `limit x 4`, drops hits the
    `within:` call rejects, widens once when short. With it false, the request body is
    byte-identical to today (`search_test.exs`, `qdrant_filter_test.exs` unchanged, green).

### PR 2 / R2: writers add `n`, backfill, stop metadata when done

- `PayloadV5.build` emits `n`; `PayloadV6 @version 6`; `n` branch + `qdrant_pace` +
  points-per-minute cap + kill switch in `ReconcileNotePayloads`; in-pass stamp;
  done check with the `is_empty n` count; section 4 gated on `n_ready?`.
- Red on main, green with the PR:
  - `payload_v5_schema_test.exs`: payload has `"n"` = note id.
  - `reconcile_note_payloads_test.exs`: a version-5 note gets ONE merge op per page with
    only `n`, no DEK fetch (Mox `expect(..., 0)` on the crypto/DEK seam), stamps 6;
    points already holding `n` are not sent.
  - `reconcile_note_payloads_pacing_test.exs` (new, like
    `refresh_keyword_vectors_pacing_test.exs`): disk at the gate snoozes with no Qdrant
    write; kill switch snoozes.
  - `data_migrations` test: `:done` only when no note is below 6 AND the `is_empty n`
    count over live points is 0; a count of 1 keeps it `:more`.
  - `indexing_test.exs`: with `n_ready?` true, a frontmatter-only edit makes zero
    `/points/payload` calls and new points carry exactly `u`, `v`, `n` (red on main:
    today it PATCHes every reused point). With it false, the refresh still runs and
    carries `n`.
  - `repath_note_index_test.exs`: with `n_ready?`, no `set_payload` call, one
    `RefreshKeywordVectors` job.
- Staging run before prod: full sweep on staging, record the disk curve and gate counts.

### PR 3 / R3: contract

- Section 5. Keeps: the `n` sweep branch, `n_ready?`, the `:too_wide` fallback (so an
  install jumping from before R1 straight to R3 heals itself: boot creates the `n`
  index, writers write `u`, `v`, `n`, the sweep backfills, reads fall back to the
  post-filter until done, then the index drop runs).
- Red on R2, green on R3:
  - `drop_old_payload_indexes_test.exs`: after `n_ready?`, one `DELETE /index/<field>`
    per old key, none for `u`/`v`/`n`, 404 treated as done; before `n_ready?`, nothing.
  - `qdrant_layout_test.exs`: `payload_indexes/2` lists only `u`, `v`, `n`.
  - Skipped-release test: not done, old filter code absent, a filtered search sends no
    old-key condition and returns the right notes through the post-filter.
  - `no_payload_metadata_writes_test.exs` (meta, grep): no `overwrite_payload`,
    `delete_payload_keys`, `set_payload_by_filter` left in `lib/`.
  - Deleted with their code: `qdrant_overwrite_payload_test.exs`,
    `payload_v6_test.exs`, `payload_v6_db_parity_test.exs`, drift-heal cases of
    `reconcile_note_payloads_test.exs`.

Self-host: every step is boot-time or a data migration; no env, no command. Any skipped
release is safe (R3 contains the index create, the sweep and the fallback).
Rollback: R2 to R1 keeps old filters (R1 ignores `n`); R3 to R2 after the index drop
is safe only once `n_ready?` (R2 then reads by `n`); before it, R3 does not drop.

## 7. Risks and staging checks

- **CPU, not disk, is the binding limit.** mx1 has 0.5 vCPU and is already busy
  (design doc). The sweep's optimizer work competes with search. Mitigation: the
  points-per-minute cap and the optimizer gate; watch search p95 during the sweep and
  lower the cap by override if it moves.
- **Dual metadata window:** until done, the refresh keeps running AND now carries `n`;
  the sweep adds ~2.8x today's average rewrite rate for ~15 h (at the 1,000/min default). After done, rewrites
  drop to zero.
- **Recall on wide filters** (`:too_wide`), measured only on staging's largest user
  (988 notes).
- **Rolling deploy**: a previous-release node can write points without `n` after a note
  is stamped; the done count catches it, and the sweep re-selects via that count.
- Staging, before prod: the `n` index create time; the full sweep's disk curve vs the
  formula above (staging bytes per point differ, so check the SHAPE: peak, vacuum,
  return); gate counts by reason; search p95 and recall@10 per filter width
  (`{:ids}` small, near 10k, `{:exclude}`, `:too_wide`); payload writes/day after done.
- Prod read-only before R2: confirm disk is still ~38% and the strict limit 93%.

## Decisions needed

- D1 sql-lane: add `within: note_ids` to the resolver and say how cross-vault grants
  resolve.
- D2 Backfill rate cap default: 1,000 points/min (~15 h, ~2.8x today's average
  rewrite rate). Lower it if search p95 matters more than finishing within a day.
