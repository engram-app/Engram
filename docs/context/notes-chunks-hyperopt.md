# notes + chunks hyper-optimization: addendum to the v5 one-time rebuild

Status: design only, read-only research (2026-10-20). Nothing was run against code or prod except read-only Grafana/VictoriaMetrics queries. Sources: backend `origin/main` 98bfb5be2, wave PR #2088 (`perf/db-scale-wave-1`, ed89acccf), v5 PR #2067 (`feat/chunker-v5` a37e081cb) plus its unmerged siblings `feat/v5-chunk-text` d463821c8, `feat/v5-payload`, `feat/v5-vector-cache`, the v5 plan (`docs/chunker-v5-plan` 446152084), and the audit working files (`pg-static-audit.md`, `pg-prod-evidence.md`, `pgaudit/*.json`, `db-wave-{1,2}-plan.md`).

Labels: **[measured]** = prod numbers (pg_stat since 2026-06-11, widths.json, VictoriaMetrics 7d). **[code]** = read in source, file:line on origin/main unless marked v5. **[est]** = model or projection; assumptions stated.

What this builds on, so nothing is duplicated:
- **Wave 1 (#2088, done):** `kind='note'` on path lookups, `notes_vault_path_tombstone_index`, `notes_reconcile_due`, `notes_crdt_head_missing_index`, GIN(tags_hmac) dropped, feed and worker fetch stop reading `crdt_state_*`, STORAGE EXTERNAL on ciphertext, timeouts, Oban fixes, batched vault purge.
- **Wave 2 (#2088, in progress):** whole-vault scan fixes (list_tags/folders/types/embed_status/snapshot), tombstone GC, note_links slimming, dead/redundant notes indexes (user_updated, user_deleted, fm_*, embed_pending), crdt_update_log/note_revisions FK drops, RLS uuid compare, NOTIFY triggers, revision touch, vaults trigger, inc_notes_count batching.
- This addendum is everything that **changes the shape** of `notes` and `chunks` (columns, types, table split, keys), which the waves deliberately left to the v5 rebuild, plus the call-count work on the four hot paths that neither wave touched.

**Blocking finding first: migration version collision.** Wave 1 has `priv/repo/migrations/20261020120000_tune_oban_jobs_storage.exs`; `feat/v5-chunk-text` has `20261020120000_add_chunks_text_ciphertext.exs` (and `..120001_index_chunks_with_text.exs`). Ecto refuses duplicate versions, so whichever merges second breaks `mix ecto.migrate` / boot [code]. Rename the v5 ones to a timestamp after `20261020120710` before PR-11 merges.

## 0. Prod facts this design rests on

| fact | value | label |
|---|---|---|
| users / users with notes | 413 / 228 | measured |
| note rows / live notes / folder rows / trashed | 34,867 / 27,588 / 4,001 / 4,871 | measured |
| notes per user | p50 1, p90 70, p99 1,158, max 10,000 | measured |
| chunks | 553,774; p50 user 5, p90 527, p99 12,531; top 5 users hold 80% | measured |
| chunks per live note | 20.1 (v5 targets ~5.2: points cap = notes x 6) | measured / v5 plan |
| notes bytes per row | 19.1 KB: heap 1.53 KB, indexes 1.39 KB, TOAST 15.9 KB | measured |
| content / crdt_state per row (avg over non-null) | 7,977 B / 8,292 B (both zstd then AES-GCM; nonce 13 B = format 1, so compression **is** landing) | measured |
| chunks bytes per row | 425 B: heap 247, indexes 178 | measured |
| notes updates since June | 401,302, HOT 154,826 (38.6%), moved page 170,841 (42.6%) | measured |
| chunks writes since June | 1.13M inserts, 579k deletes, 41k updates (3k HOT) | measured |
| 7-day statement counts (Ecto source) | `tenant_txn` (BEGIN+COMMIT) 613,718; `tenant_enter` 308,896; `notes` 290,846; `chunks` 77,038 | measured |
| 7-day client-side time | `tenant_txn` 774 s + `tenant_enter` 290 s = **1,064 s** vs `notes` 570 s, `chunks` 209 s | measured |
| mean per tenant round trip | BEGIN/COMMIT 1.26 ms, set_config 0.94 ms | measured |
| 7-day traffic | POST /api/mcp 84k, GET /api/mcp 25k, GET /api/sync/manifest 16.3k, GET /api/vault/tree 5.9k, GET /api/folders/explicit 6.4k; channel `crdt_msg` 83k, `crdt_index_msg` 76k, `crdt_create` 26k, `crdt_catchup_since` 23k; checkpoints 45.7k | measured |

The tenant envelope (BEGIN, set_config, COMMIT) costs about 1.9x all `notes` query time [measured]. On this instance one round trip is ~1 ms, so **every removed round trip on a hot path is worth ~1 ms of latency and a pool slot for that long.**

100k-user projection method: linear from prod (x242.1), which keeps the real whale mix (top 5 = 80% of chunks). That gives 8.44M note rows, 6.68M live notes, 134M chunks at today's chunking, 34.7M points at v5's ~5.2 per live note [est]. A "no whales" sensitivity is in section 5.

## 1. Query inventory

Frequency classes: **K** per keystroke flush (plugin debounces ~2 s), **C** per checkpoint (eager 250 ms + settle 5 s + ceiling 60 s, so >= 2 per edit burst), **S** per sync request, **P** per catch-up page, **M** per MCP/REST call, **H** per search, **J** per job, **T** periodic cron. Index names are prod's. "V" = rows in the vault, "U" = the user's live notes, "B" = rows sharing a basename.

### 1.1 Sync push (REST `POST /api/notes`, `notes_controller.ex:38` -> `Notes.upsert_note/4`)

Edit of an existing note: **15 RT, 1 notes version (non-HOT), ~15 notes index inserts** [code]. Create: **~19 RT** [code].

| # | file:line | shape | index / rows | class |
|---|---|---|---|---|
| 0 | `plugs/rotation_lock_check.ex:37` -> `crypto/rotation_gate.ex:39` | `SELECT dek_rotation_locked_at FROM users` autocommit, before the txn | users pkey | S |
| 1-2 | `repo.ex:287,295` | BEGIN; `set_config(tenant), set_config(role)` | | S |
| 3 | `notes.ex:2262` (query `3262-3267`) | `SELECT notes.*` by path, de-TOASTs content AND crdt_state | path_v2 after wave 1 (was a vault scan) | S |
| 4 | `notes.ex:2673` -> `crdt_persistence.ex:483` | `SELECT crdt_update_log.*` tail | (note_id, inserted_at), usually 0 | S |
| 5 | `notes.ex:2409` -> `vaults.ex:78-83` | `UPDATE vaults SET change_seq+1 RETURNING`; lock held to COMMIT across 6-13 | vaults pkey | S |
| 6 | `notes.ex:2429/2536` (fence `2518-2526`) | `UPDATE notes SET` ~25 cols incl. both bodies, **fence `crdt_state_ciphertext = $bytea`** (sends and de-TOASTs the whole state) | pkey; non-HOT; trigger `notes_crdt_head_invalidate` | S |
| 6h | `revisions.ex:224-229,129-206` | history on: SELECT open revision + touch/close/insert, savepoint-wrapped | +2-3 RT | S |
| 7-12 | `content_commit.ex:27-33` -> `embed_note.ex:954-976`, oban basic | EmbedNote unique replace (advisory lock, probe, INSERT/UPDATE), ExtractNoteLinks unique, FinalizeRevision | 6-9 statements **inside** the vault-locked txn | S |
| 13 | `notes_controller.ex:702` -> `links.ex:827-840,944,1053` | `links_for_note` for the response | 1-3 statements under the vault lock | S |
| 14 | | COMMIT | | S |
| create +| `notes.ex:1530, 4301, 3316, 997, 999, 1001, 6737` | `classify_by_id SELECT *`, cap read, `recently_deleted_twin?`, INSERT ON CONFLICT DO NOTHING, **re-fetch `SELECT *` by path** to detect the race, `usage_meters` upsert, vault-populated probe | | S |

### 1.2 CRDT live edit, room open, checkpoint

| op | file:line | statements | RT | notes versions | class |
|---|---|---|---|---|---|
| append (`crdt_msg`, `crdt_channel.ex:240`) | `crdt_persistence.ex:232,330-351` | BEGIN; set_config; one CTE: INSERT crdt_update_log (4 index inserts, 3 FK KEY SHARE locks on notes/users/vaults) + `UPDATE notes SET crdt_head=NULL WHERE ... AND crdt_head IS NOT NULL` + `SELECT seq`; COMMIT | 4 | 0, or 1 after a re-warm (HOT on main; **non-HOT after wave 1's `notes_crdt_head_missing_index`**, whose predicate column is `crdt_head`) | K |
| room open | `crdt_channel.ex:2175-2238`, `notes.ex:3195`, `crdt_persistence.ex:70-184`, `notes.ex:3211` | `note_in_vault?` txn; bind txn (`SELECT notes.*` + tail); `get_note_by_id` txn (`SELECT *` + decrypt every field) **only to read `path`** | 13 | 0 | per room |
| genesis `crdt_create` (first sync, 26k/7d) | `notes.ex:1123-1295`, `crdt_channel.ex:1301-1500`, `crdt_checkpoint.ex:143-655,799` | INSERT an empty-body row, then checkpoint it in the same txn: 2 vault seq bumps, INSERT + non-HOT UPDATE, **5 full `SELECT notes.*`** + `version` read + populated probe, rotation SELECT, NoteCommitted INSERT + pg_notify after commit | ~21 | 2 (1 non-HOT) | per new note |
| materializing checkpoint (45.7k/7d) | `crdt_checkpoint.ex:110-310,622-645,997` | rotation SELECT; BEGIN; set_config; `SELECT notes.*` (content de-TOASTed + decrypted); vault seq bump; `UPDATE notes SET` all content columns + crdt_state + content_hash + version + seq + updated_at (fence on `crdt_state_nonce`); DELETE tail ids; COMMIT; NoteCommitted INSERT + notify; async EmbedNote/ExtractNoteLinks unique inserts (5 statements each, own txns) | 10 (+2-3 history) | 1 non-HOT | C |
| compaction (text unchanged) | `crdt_checkpoint.ex:571-583` | same envelope, `UPDATE notes SET crdt_state_*, dek_version`; new TOAST value **even when nothing changed** | 6-7 | 1 HOT-able | per unbind |

Why every content write is non-HOT today [code]: it changes `seq` (feed index), `updated_at` (`idx_notes_user_updated`, `notes_recent_index`, `notes_reconcile_due`), `content_hash` (reconcile predicate), and **`path_nonce` + `link_keys_stamp` on every write** because path and folder are re-encrypted with a fresh nonce even when the path did not change (`notes.ex:7113-7132`, `links.ex:122-128`, `crdt_checkpoint.ex:593-601`), and those are in the `notes_link_keys_stale_index` predicate.

### 1.3 Catch-up pull (`crdt_catchup_since` 23k/7d, `sync.ex:30-53`, `notes.ex:4353-4777`)

| # | file:line | shape | problem | class |
|---|---|---|---|---|
| 1 | `notes.ex:4400` -> `4565-4573` | probe txn: `pg_column_size(content_ciphertext)` over the page, `LIMIT 501` | **keyset written as `seq > X OR (seq = X AND id > Y)`** (`4372`): the index condition is `vault_id` only, so every page scans the vault from seq 0 and discards rows below the cursor [code] | P |
| 2 | `notes.ex:4406` | page txn: same WHERE, all columns except crdt_state (after wave 1 item 11) | same OR; still reads embed_*, hmacs, link keys | P |
| 3 | `notes.ex:4631-4737` (`@resolve_chunk 50`) | per 50 live `.md` rows: txn with tail SELECT + `SELECT notes.* WHERE id IN (refresh)`, sent even when the list is empty | 5 RT per 50 rows | P |
| 4 | `attachments.ex:1279-1291` | attachments feed, same OR keyset | | P |

Page of 500 = ~62 RT; page of 100 = ~22 RT [code]. Manifest (`sync_controller.ex:149-180`, 16.3k/7d): one txn, narrow select over all live notes of the vault (id, dek_version, path ct/nonce, content_hash, seq, crdt_head), well shaped [code].

### 1.4 MCP read and REST reads (84k MCP POSTs/7d)

| file:line | function | shape | issue | class |
|---|---|---|---|---|
| `notes.ex:3250/2711` | `get_note` (MCP get_note `handlers.ex:313`, get_notes `352`, resources/read, REST show) | path lookup, `SELECT *` | get_notes = up to 20 statements, **each its own with_tenant** (4 RT each = 80 RT) | M |
| `notes.ex:3246` | `note_exists?` (create_note) | `SELECT *` | full row for existence | M |
| `notes.ex:2916` | `get_note_metadata` (similar_to, once per vault) | `SELECT *` | needs id + dense flag | M |
| `notes.ex:2721,2877,2898` | rmw for append/edit/patch | path lookup + 3 ARRAY tail subqueries, `lock_for_write`, re-read on miss | `append_or_create` (`handlers.ex:1146`) can do 6 path lookups | M |
| `notes.ex:3808-3832` | `delete_note_reporting` | `SELECT *` then tombstone UPDATE | only id used | M |
| `notes.ex:3904` | `delete_note_by_id` | full read + decrypt, then delete **by path** (second lookup) | | M |
| `notes.ex:3434, 3524-3550` | rename: `note_ids_at`, lookup, `target_query` `SELECT *` for conflict, `rename_with_retry` re-runs lookup | 3 lookups | M |
| `notes.ex:5414` | `list_recent_notes` | `notes_recent_index` | fine; per vault for cross-vault | M |
| `notes.ex:5446` | `list_notes_in_folder` | (user,vault,folder_hmac) | reads tombstones in the folder too | M |
| `notes.ex:5296,4907,5333/5364,4960` | list_tags(_with_counts), list_folders_with_counts, list_types | whole live vault, decrypt per row (wave 2 item A) | | M |
| `notes.ex:3211` | `fetch_note_by_id(:all)` for backlinks / channel (`crdt_channel.ex:1301,1500,2224`) | `SELECT *` + decrypt content | most callers need path only | M |
| `release_index_entries.ex:117` | per-id `get_note_by_id(:all)` | N+1 | J |
| `notes.ex:4162,4264` | batch move: `resolve_moves` per id, `apply_moves` = full `rename_note` per note | N+1, O(N x 3 lookups) | M |

### 1.5 Search hydrate (Qdrant hit -> chunks/notes)

| file:line | shape | issue | class |
|---|---|---|---|
| `search.ex:666-689` -> `notes.ex:171-206` | one query: `chunks c JOIN notes n` on `c.qdrant_point_id IN ($K)` (K up to `max(limit*4,20)` when reranked/diversified), 29 `@note_meta_fields` | **decrypts per hit, not per distinct note** (`notes.ex:189`); reads folder ct, seq, version, mtime, parse_* it never uses | H |
| `search_controller.ex:167-178,211` -> `notes.ex:3342-3375` | REST second query per distinct vault, each its own with_tenant, to recover `note.id` | step 1 already joined `c.note_id` | H |
| `handlers.ex:1287-1310` | similar_to: `SELECT *` per vault + `SELECT qdrant_point_id FROM chunks WHERE note_id ORDER BY position` | | H |
| v5 `notes.ex:226-262` `search_hits_by_qdrant_points` | same join plus `text_ct/nonce, heading_ct/nonce` | still per-hit decrypt | H |

### 1.6 Embed pipeline (per content change; prod avg N=17 chunks, Delta=1 changed)

**~22 RT, 5 transactions (15 RT of tenant envelope), 3-4 notes UPDATEs, N chunk DELETEs + N INSERTs (85 chunk index inserts)** per run on main; v5 adds 1-2 more notes UPDATEs, 2 `FOR UPDATE` reads, an unconditional 20-column flat-field UPDATE plus `note_attrs` delete/reinsert, and a per-pass `count(*) FROM chunks WHERE user_id` [code].

| # | file:line | shape | class |
|---|---|---|---|
| 1 | Oban fetch/ack | 2 job UPDATEs | J |
| 2 | `embed_note.ex:121` -> `notes.ex:3130` | T1 `SELECT *` (wave 1: no crdt_state) + `accounts.ex:51` user+subscription + `SELECT * vaults` | J |
| 3 | `crash_guard.ex:97-104` | T2 `UPDATE notes SET embed_started_*` (notes UPDATE #1) | J |
| 4 | `indexing.ex:1120-1126` | T3 `SELECT context_hmac, qdrant_point_id, token_count FROM chunks WHERE note_id` | J |
| 5 | `usage_meters.ex:69-110` | token reservation upsert | J |
| 6 | `keyword_index/stats.ex:35-58` | avgdl: `avg(token_count) FROM chunks WHERE vault_id`, **heap read of every chunk in the vault** on a 10-min per-node cache miss | J |
| 7 | `indexing.ex:385-390` | T5 `DELETE FROM chunks WHERE note_id` + `INSERT` all N rows ("wholesale rewrite") | J |
| 8 | `indexing.ex:408-418, 239-251` | `UPDATE notes SET payload_hash` (if changed), OKF heal | J |
| 9 | `embed_note.ex:777-783` | `UPDATE notes SET embed_hash, chunker_version, keyword_version, dense_indexed_hash, embed_model, embed_retry_after, embed_budget_parked` (non-HOT: predicate column) | J |
| 10 | `crash_guard.ex:110` | `UPDATE notes SET embed_started_*=NULL`, **same row, same txn as #9** | J |
| v5 | `indexing.ex:226-233,327-336,726-752,1083-1133,2577-2587,2773-2781` (v5) | tier read, `count(*) chunks WHERE user_id` every pass, `content_current!` + `stamp_index_tier` two `FOR UPDATE` reads of one row, re-encrypt + re-insert **every** chunk's text each pass, unconditional flat-field + note_attrs rewrite | J |

Sweeps [code]: reconcile every 5 min (`reconcile_embeddings.ex:110-188`, wave 1 indexed it; it still stamps `embed_retry_after` on notes with a pending job before dedupe, `173-188` vs `288-291`), keyword sweep (`362-414`, unindexed), `index_versions.ex:37`, orphan sweep daily over **all chunks** joined to notes and vaults (`orphan_sweep.ex:557-570`, 270 pages at prod), resparse/token_count bulk update (`indexing.ex:1307-1353`), rename clears `context_hmac` on all N rows (`indexing.ex:524-535,658-668`) so the next pass re-embeds everything. v5 budget sweep: cross-tenant `SELECT user_id, count(*) FROM chunks GROUP BY user_id` **on every 5-minute tick of the 04:00 hour (12x/day)** (`reconcile_embeddings.ex:229,507,882` v5).

### 1.7 Links (per note write via ExtractNoteLinks, per rewrite job)

| file:line | shape | index | issue |
|---|---|---|---|
| `links.ex:984-1042` `candidate_queries` | stale / pathed / shortest_len | stale partial; path_ci; basename partial | shortest_len visits all B heap rows (733 for the `index.md` hub) to check kind/keys/deleted |
| `links.ex:491,636` | `fetch_candidates_by_hmac`, `do_live_basename_count` | basename partial | B per job |
| `rewriter.ex:223` | `current_path`: `SELECT *` + decrypt content to read the path | pkey | J |
| `rewrite_note_links.ex:264` | `tombstone_old_path` ORDER BY seq DESC LIMIT 1 | wave 1 tombstone index (vault_id, path_hmac) helps; still sorts | J |

### 1.8 Listings, tree, periodic (whole-vault or whole-table)

Covered by wave 2 item A (list_tags, list_types, folders, embed_status, snapshot) [code: agent inventory]. Additional ones that matter for the schema:
- `type_hmac` index: 183k scans / 171M tuples [measured] is mostly a **planner side effect**: it is the smallest `(user_id, vault_id, ...)` index (mostly NULL keys deduplicated), so unselective `scoped/2` queries land on it; its only real reader is `list_types` [code].
- `idx_notes_user_created_rank`: 41k scans / 118M tuples [measured]; its designed reader (`IndexCap.rank_below_cap?`) is gone. Remaining users: `BackfillCrdtHead.enqueue_all` (hourly, every user), `embed_status`, `recount_notes!` [code].
- `backfill_link_keys.ex:105` binds the stamp as a parameter, so it can never use the literal-predicate `notes_link_keys_stale_index` and reads every user row daily at 04:00 [code].
- `tenant_sweep.ex:74` keyset `(user_id, id)` has no index (rotation, reencode) [code].
- Folder marker lookups (`notes.ex:460,498`) omit `deleted_at IS NULL`, so they read every note in the folder instead of the unique marker index [code].

## 2. Target schema

Design rule: **one table per writer.** Today four writers rewrite the same wide `notes` row: sync/checkpoint (content, metadata, seq), CRDT appends (crdt_head), the embed pipeline (5 stamps per run), and the indexing pass in v5 (index_tier, chunk_count, 20 flat fields, rebuild_paid_at). Every one of those writes copies the whole inline tuple and, unless HOT, inserts into every notes index. [code: section 1]

Split `notes` into three tables plus `note_index_state`, all 1:1 on `note_id`:

| table | writer | reader | update frequency |
|---|---|---|---|
| `notes` (core metadata) | sync push, checkpoint, rename, delete, folder ops | everything (listings, manifest, feed, links, path lookups) | per checkpoint / push / rename |
| `note_bodies` (content + CRDT state) | checkpoint, push, CRDT seed, DEK rotation | pull, MCP read, embed, room bind, export | per checkpoint / push |
| `note_index_state` (everything the indexer derives) | EmbedNote, reconcile, v5 indexing pass, budget sweeps | reconcile, embed, billing usage, (future) filter search #2083 | per embed run |

`crdt_head` moves with `crdt_ct` into `note_bodies`, so the per-keystroke head reset and the `notes_crdt_head_invalidate` trigger stay on one narrow table and never touch `notes` (2.2).

### 2.1 `notes` (core), target

Column order is by alignment: 8-byte, then uuid (align `c`, so no padding), then 4/2/1-byte, then varlena. 32 columns, under the 72-column mark where the tuple header grows from 32 to 40 B. v5 as written takes `notes` to 79 attributes (55 + index_tier + chunk_count + 20 flat + rebuild_paid_at + ctime), which costs **+8 B header on every tuple version** [code + PG `t_hoff` rule]; dropped columns keep counting until a table rewrite.

| # | column | type | B | null | for | read by |
|---|---|---|---|---|---|---|
| 1 | seq | int8 | 8 | NN | change feed, ETag, recent | feed, manifest, recent, tree |
| 2 | created_at | timestamp | 8 | NN | API | REST/MCP output |
| 3 | updated_at | timestamp | 8 | NN | API, conflict UI | REST/MCP output (no index any more) |
| 4 | deleted_at | timestamp | 8 | 86% null | tombstone | every live predicate |
| 5 | mtime | float8 | 8 | 72% null | plugin mtime | pull, manifest-free |
| 6 | ctime | float8 | 8 | null | PR-1b | v5 payload `cr` fallback |
| 7 | fm_timestamp | timestamptz | 8 | 93% null | OKF | API, payload build |
| 8 | fm_created | timestamptz | 8 | 92% null | OKF | API, payload build |
| 9 | id | uuid | 16 | NN | PK (uuidv7, app-minted) | all |
| 10 | vault_id | uuid | 16 | NN | scope | all |
| 11 | user_id | uuid | 16 | NN | RLS only (no index leads with it) | RLS policy |
| 12 | path_id | uuid | 16 | null for folders | **128-bit truncated path HMAC**, = v5 `FilterId.from_hmac` | path lookups, unique |
| 13 | folder_id | uuid | 16 | NN | folder HMAC, truncated | list_folder, folder counts |
| 14 | basename_id | uuid | 16 | null for folders | links | Links candidates |
| 15 | path_ci_id | uuid | 16 | null for folders | links (case-insensitive) | Links pathed |
| 16 | type_id | uuid | 16 | 95% null | OKF type | list_types |
| 17 | version | int4 | 4 | NN | conflict counter | push fence |
| 18 | dek_version | int2 | 2 | NN | AAD/rotation (was int4) | decrypt |
| 19 | path_length | int2 | 2 | null for folders | shortest-link tie-break (was int8; Linux PATH_MAX 4096) | Links shortest |
| 20 | link_keys_v | int2 | 2 | null | replaces 19 B `link_keys_stamp` after the rebuild recomputes every key (all writers stamp) | stale-keys partial index |
| 21 | parse_status | int2 | 2 | NN | was text 'ok' | API |
| 22 | is_folder | bool | 1 | NN | replaces `kind text` (5 B) | every predicate |
| 23 | content_hash | bytea(32) | 33 | null for folders | sync equality (hex at the API edge) | manifest, push |
| 25 | path_ct | bytea | ~110 | null for folders | `nonce‖ct` merged (was 2 columns) | everything that shows a path |
| 26 | title_ct | bytea | ~58 | null | NULL when title = basename(path) (see 2.5) | listings |
| 27 | tags_ct | bytea | ~40 | null | tags | listings, tag list |
| 28 | tags_ids | uuid[] | ~30 | NN '{}' | tag grouping without decrypt (wave 2 item A) | list_tags_with_counts |
| 29 | type_ct | bytea | ~40 | 95% null | | list_types |
| 30 | description_ct | bytea | ~200 | 99% null | | API |
| 31 | resource_ct | bytea | 0 | 100% null today | OKF resource | API |
| 32 | folder_ct | bytea | ~70 | **folder rows only** | notes derive folder = dirname(path) (`Helpers.extract_folder/1`) | folder listings |
| 33 | parse_reason | jsonb | 179 | 99.7% null | | API |

Dropped from `notes` (moved or gone):
- `content_ciphertext`, `content_nonce`, `crdt_state_ciphertext`, `crdt_state_nonce` -> `note_bodies` [code: P1-4, 10.3]
- `embed_hash`, `dense_indexed_hash`, `embed_started_hash`, `embed_started_at`, `embed_started_by`, `embed_crashes`, `embed_retry_after`, `embed_budget_parked`, `chunker_version`, `keyword_version`, `embed_model`, `payload_hash` -> `note_index_state` [code: A.1 #5,#11,#13,#14]
- v5 `index_tier`, `chunk_count`, `rebuild_paid_at`, and the 20 flat columns -> `note_index_state` (never on `notes`)
- `folder_ciphertext/nonce` on note rows (70 B avg, measured) -> derived from path
- all `*_nonce` columns (8 on core) -> merged into their ciphertext
- `kind` -> `is_folder`; `link_keys_stamp` -> `link_keys_v`
- hex text hashes -> bytea; 32-byte HMACs -> uuid (16 B, fixed width, no varlena header)

Why 128-bit HMACs are safe: the unique `(vault_id, path_id)` constraint needs no collision inside one vault; at 10k paths the birthday probability is about 2^-101. v5 already truncates to 128 bits for every Qdrant filter id (`FilterId.from_hmac`, first 16 bytes) [code: v5 plan 15.3], so the PG column becomes byte-identical to the Qdrant id and the v5 payload builder stops re-deriving it.

Storage settings:
- `fillfactor = 90`. Checkpoints change `seq` (indexed), so they are non-HOT by design; the slack keeps the new version on the same page (prod today: 42% of notes updates moved to a new page, `n_tup_newpage_upd` 170,841 of 401,302 [measured]) and lets metadata-only stamps (title, tags, mtime) go HOT.
- default `toast_tuple_target`: with the bodies gone the widest core row is ~1 KB (a long description), so nothing toasts in practice.
- small ciphertexts keep the default EXTENDED storage; they never reach the threshold.

### 2.2 `note_bodies`, new

| column | type | B | for |
|---|---|---|---|
| note_id | uuid PK, FK notes ON DELETE CASCADE | 16 | 1:1 |
| user_id | uuid | 16 | RLS (no FK, no index) |
| dek_version | int2 | 2 | body may be rotated separately from core |
| content_ct | bytea STORAGE EXTERNAL | inline < 2 KB, else 18 B pointer | `nonce‖zstd+gcm`, the materialized projection |
| crdt_ct | bytea STORAGE EXTERNAL | same | Y.Doc state |
| crdt_head | bytea(32) | 33, 17% null | manifest head (was 43-char b64 text); the existing BEFORE UPDATE trigger moves here unchanged |

- One index (pkey). `fillfactor = 75`: a p50 note (content ~1 KB, state ~1 KB) is a ~2 KB inline tuple, 3 per page; 25% slack holds one new version so a checkpoint is HOT with 0 index inserts. TOASTed bodies are ~100 B heap tuples and HOT trivially.
- Writers must **omit unchanged columns from SET**: re-sending identical bytes as a parameter re-toasts them (new TOAST chunks + TOAST index entries) [PG rule]; only an omitted column keeps its pointer. A structural (CRDT-only) checkpoint sets `crdt_ct` alone.
- Why not keep content on `notes` (the audit's 10.3 option): p50 notes are ~1 KB, so their content would sit inline in the core row and the manifest/tree/link scans would read 3-5x the pages. Moving both bodies keeps the core row ~0.5 KB.

### 2.3 `note_index_state`, new (replaces the embed stamps on `notes` and v5's additions)

| column | type | B | replaces |
|---|---|---|---|
| retry_after | timestamptz | 8, 82% null | embed_retry_after |
| started_at | timestamptz | 8, null | embed_started_at (crash guard) |
| rebuild_paid_at | timestamptz | 8, null | v5 Task 16.3 |
| fm_updated, fm_reviewed, fm_expires, fm_due | int8 | 8 each, ~95% null | v5 flat (see 2.6) |
| fm_priority | float8 | 8, null | v5 flat |
| note_id | uuid PK, FK notes CASCADE | 16 | |
| user_id | uuid | 16 | RLS |
| status_id, author_id, rev_by_id, proj_id | uuid | 16 each, null | v5 `*_hmac` (truncated, = Qdrant id) |
| chunk_count | int4 | 4, null | v5 chunk_count (was bigint); see 4.3 for making it always stamped |
| points | int2/int4 | 4 | NEW: points this note holds, so the per-user count is a sum, not a chunks scan |
| chunker_v, keyword_v, model_id | int2 | 2 each | chunker_version int8, keyword_version int8, embed_model text (~15 B) |
| index_tier | int2 | 2, null | v5 index_tier text |
| crashes | int2 | 2, null | embed_crashes int8 |
| pending | bool | 1 | NEW: content changed since the last successful index (replaces the `embed_hash <> content_hash` comparison) |
| dense_ok | bool | 1 | dense_indexed_hash (it only ever equals content_hash or NULL) [code: audit 6 #7] |
| parked | bool | 1 | embed_budget_parked |
| payload_hash | bytea(16) | 17 | was 32 B; change detection only |
| started_by | text | null | crash-guard node |
| src_ids | uuid[] | null | v5 src_hmac bytea[] |
| fields_ct | bytea | ~120, null | ONE envelope holding every flat field's display value (v5 has 5 ciphertext+nonce pairs: ~29 B GCM/nonce overhead each) |

Removed outright: `embed_hash` (redundant with `pending`, see 4.3), `embed_started_hash` (always equals content_hash at stamp time, never cleared) [code: crash_guard.ex:99-111].

- `fillfactor = 80`, indexes: pkey + `note_index_state_due (note_id) WHERE (pending OR NOT dense_ok) AND NOT parked`. The version-stale arm is NOT in the predicate: version passes are driven by v5's rebuild manifest/queue (Task 16.1/16.2), not by reconcile [code: v5 plan], so no new index per version bump.
- `pending` is flipped false->true by content writers with `UPDATE ... SET pending = true WHERE note_id = $1 AND NOT pending`: the first checkpoint after an index run writes one narrow tuple; every later checkpoint in the edit session matches 0 rows and writes nothing.
- The embed commit clears it with a compare-and-set against the hash it indexed: `UPDATE note_index_state s SET pending = false, ... FROM notes n WHERE s.note_id = n.id AND n.id = $1 AND n.content_hash = $indexed_hash`. An edit that landed mid-run leaves `pending` true, which is exactly today's `embed_hash <> content_hash` semantics.

### 2.4 `chunks`, target (on top of v5)

| # | column | type | B | for | read by |
|---|---|---|---|---|---|
| 1 | point_id | uuid PK | 16 | **the Qdrant point id** (v5 UUIDv5) is the row key; `chunks.id` goes | hydrate, orphan sweep, reuse |
| 2 | note_id | uuid NN, FK notes CASCADE | 16 | | reuse, delete, per-note reads |
| 3 | user_id | uuid NN, **no FK, no index** | 16 | RLS only | policy |
| 4 | char_start | int4 | 4 | byte offset (v5 L4: `char_end` is a byte offset) | slicing (2.4b), resparse |
| 5 | char_end | int4 | 4 | | |
| 6 | token_count | int4 | 4 | was int8 | avgdl, metering |
| 7 | position | int2 | 2 | ordinal | (note_id, position) |
| 8 | member_fps | bytea | 8 x n, null | v5 `member_hmacs text[]` of 16-hex strings -> 8-byte prefixes concatenated: for 8 members 65 B instead of ~184 B | merged-regroup metering |
| 9 | display_ct | bytea STORAGE EXTERNAL | ~1.0 KB, null | ONE envelope `nonce‖zstd+gcm({heading_list, text})` replacing v5's text_ct+text_nonce+heading_ct+heading_nonce | search hydrate, rerank |

Dropped: `id` (+ `chunks_pkey`), `vault_id` (+ `chunks_vault_id_index`, FK), `created_at` (no reader [code: agent B found none]), `heading_path` (dead, 100% NULL [measured]), `context_hmac` (see below), user FK + `idx_chunks_user`, `chunks_qdrant_point_id_index` (it becomes the PK), v5's `chunks_with_text_user_id_id_index`.

`context_hmac` (65 B hex, the largest fixed part of today's row [measured]) is redundant for v5 rows: the v5 point id is `UUIDv5(note_id ‖ fingerprint ‖ ordinal)`, so "same fingerprint and ordinal in this note" is exactly "same point_id", and the reuse lookup becomes `point_id = ANY($planned_ids)`. Keep the column until the v5 pass is done (v3 rows have random ids), then contract it with PR-18. [code: v5 plan Global Constraints; confirm with the v5 owner that the UUIDv5 fingerprint is the context fingerprint]

Indexes: pkey(point_id) + UNIQUE(note_id, position). That's 2 instead of 5 on main (6 in v5).

`fillfactor = 100` stays: rows are inserted and deleted, rarely updated (41k updates vs 1.13M inserts since June [measured]).

#### 2.4b Option: no chunk text in Postgres at all (biggest single bytes item, v5 owner decision)

v5 Task 11 stores ~1 KB of encrypted text per point. The same bytes already exist in `note_bodies.content_ct`: a point's display text is `content[char_start, char_end)` (a merged group spans its members' consecutive range), and the heading list is cheap to recompute from the same slice's context or to store alone (~40 B).

| | v5 as planned | slice from content |
|---|---|---|
| bytes per point | ~1.0-1.1 KB envelope + 2 nonces | 0 (heading-only envelope ~45 B if stored) |
| at 100k users (34.7M points) | ~37-40 GB | ~1.5 GB |
| hydrate cost | K chunk rows | K distinct notes' content (avg 8 KB, p50 ~1 KB), decrypted once per note |
| staleness | text matches the point exactly | an edit not yet indexed shifts offsets: detect with a 4-byte slice checksum per point and fall back to the chunk text re-derived by the NIF chunker on the current content |
| whale notes | fine | a hit inside a 10 MiB note decrypts ~3 MB zstd: keep `display_ct` only for notes over a threshold (e.g. content > 256 KB) |

Recommendation: the hybrid (store `display_ct` only above the size threshold). It keeps v5's guarantees for big notes and removes ~90% of the chunk-text bytes. This is a v5 design change; it must be decided before PR-11 merges, because the v5 pass writes every row once.

### 2.5 Smaller column decisions

| item | saving | note |
|---|---|---|
| merge `*_nonce` into `*_ct` (`nonce‖ct`) | ~1 B header + null bit per pair; ~10 B/note core, 2 B/chunk | needs a crypto read path that accepts both layouts until the rebuild rewrites every row |
| one metadata envelope for path+title+tags | ~60 B/note (two GCM tags + nonces) and 2 fewer AES-GCM inits per listed row | manifest decrypts path only today (`PathCrypto.decrypt_many!`); a combined envelope decrypts ~100 B more per row. Medium value |
| `title_ct` NULL when `title == basename(path)` | 58 B on notes without an H1/frontmatter title | `extract_title/2` falls back to basename [code: helpers.ex:145]; measure the fraction first |
| `folder_ct` only on folder rows | 70 B/note [measured avg] | `extract_folder/1` [code: helpers.ex:170] |
| `dek_version` int4 -> int2 | 2 B | |
| `resource_ct` (100% null) | 0 B today | keep, it is an OKF field |
| zstd with a trained markdown dictionary for content | est 15-30% on p50 (~1 KB) notes | public-corpus dictionary only (no user plaintext); new envelope format byte |
| Yjs v2 update encoding for `crdt_ct` | est 5-15% after zstd | measure on the prod sample first |

### 2.6 v5 flat fields: where they go

v5 `20261020100000` adds 20 nullable columns to `notes` and `20261020100001` adds 9 partial indexes `(user_id, col) WHERE col IS NOT NULL` + a GIN, for a reader that does not exist yet ("API and MCP filter-only search over them is follow-up issue #2083, NOT v5" [code: v5 plan 15.6]).

- Put the exact-key ids and dates in `note_index_state` (2.3), written by the same pass that writes the payload. `notes` is never touched by the indexer.
- Ship **no indexes** for them in v5. When #2083 lands, `CREATE INDEX CONCURRENTLY` on `note_index_state` is zero-operator and sized to the real query. Today each index costs a write per value change and its predicate column blocks HOT on whatever table holds it.
- `fm_updated` (int8, v5 precedence) next to `fm_timestamp` (timestamptz, OKF precedence) stores "updated" twice with different alias rules [code: v5 flat_fields.ex:19-20]. Pick one rule; keep one column.
- `note_attrs`: drop its `id` (PK `(note_id, key_hmac, ord int2)`), drop the `user_id`/`vault_id` FKs and their indexes (the `note_id` cascade covers deletion, same as wave 2 item 5), key the lookup indexes `(vault_id, key_hmac, value_*)` without `user_id`, and gate `stamp_flat_fields` on a hash of the extracted fields (v5 deletes and re-inserts every attr row on every pass [code: agent B D.2]).

## 3. Target index set

Rules applied:
- **Lead with `vault_id`, not `(user_id, vault_id)`.** The vault determines the user; the RLS policy (`user_id::text = current_setting(...)`, or the uuid form wave 2 item 13 adopts) is evaluated as a filter and never as an index condition, so a leading `user_id` buys nothing and costs 16 B per entry [code: policy in structure.sql; PG RLS semantics]. App queries keep `user_id = $1` as a filter. Cross-vault queries (`do_note_ids_for_paths` without a vault) must pass `vault_id = ANY($user_vaults)`; do not rely on PG 18 skip scan over a 100k-value `vault_id`.
- **Partial on liveness** wherever every reader is live-only, so tombstones (14%) and folder rows (11.5%) are not indexed.
- **Every predicate column blocks HOT** (PG puts index-predicate columns in the HOT-blocking set; only summarizing BRIN indexes are exempt since PG 16) [docs]. So no index predicate may mention a column a frequent writer changes unless that writer is non-HOT anyway.
- **One index serves two queries** where the key order allows (feed + recent; basename + shortest).

### 3.1 `notes` (core)

| index | definition | serves | replaces |
|---|---|---|---|
| `notes_pkey` | (id) | by-id reads (4.7M scans), FK target | same |
| `notes_feed` | (vault_id, seq, id) | catch-up keyset `(seq, id) > ($s, $i)` (fixed form, 4.1), recent notes `ORDER BY seq DESC` with a live heap filter, manifest/tree vault scan, cleanup batches | `notes_vault_id_seq_id_index` (same key), **`notes_recent_index`**, `idx_notes_user_updated` |
| `notes_path_live` | UNIQUE (vault_id, path_id) WHERE deleted_at IS NULL AND NOT is_folder | every path lookup, uniqueness | `notes_user_vault_path_v2` |
| `notes_path_tomb` | (vault_id, path_id, seq) WHERE deleted_at IS NOT NULL | `recently_deleted_twin?`, `tombstone_old_path` (ORDER BY seq DESC LIMIT 1 becomes a backward probe) | wave 1 `notes_vault_path_tombstone_index` (adds seq) |
| `notes_basename` | (vault_id, basename_id, path_length) INCLUDE (link_keys_v) WHERE deleted_at IS NULL AND NOT is_folder | basename candidates, live count, **shortest_len index-only** (no heap visit per same-name row) | `notes_user_id_vault_id_basename_hmac_index` AND `..._basename_hmac_path_length_index` |
| `notes_path_ci` | (vault_id, path_ci_id) WHERE deleted_at IS NULL AND NOT is_folder | pathed link candidates | non-partial `(user_id, vault_id, path_ci_hmac)` |
| `notes_folder` | (vault_id, folder_id) WHERE deleted_at IS NULL | list_notes_in_folder, folder counts, folder_target_exists? | non-partial `(user_id, vault_id, folder_hmac)` |
| `notes_folder_marker` | UNIQUE (vault_id, folder_id) WHERE deleted_at IS NULL AND is_folder | marker lookups (after the 1.8 predicate fix), uniqueness | same, minus user_id |
| `notes_type` | (vault_id, type_id) WHERE type_id IS NOT NULL AND deleted_at IS NULL | list_types | non-partial type_hmac (5% of rows have a type) |
| `notes_link_keys_stale` | (vault_id, basename_id) WHERE basename_id IS NOT NULL AND link_keys_v IS DISTINCT FROM <current> | stale-key repair; empty after the rebuild | same idea, smallint instead of `path_nonce || '15.1.0'` |
| `notes_tomb_gc` | (deleted_at) WHERE deleted_at IS NOT NULL | wave 2 tombstone GC (cross-tenant, maintenance pool) | `idx_notes_user_deleted` |

Dropped and not replaced: `idx_notes_user_created_rank` (reader gone [code]), `notes_user_id_vault_id_fm_created_index`, `..._fm_timestamp_index` (no PG reader; Qdrant filters dates [code]), `notes_reconcile_due` and `notes_crdt_head_missing_index` (wave 1; they move to `note_index_state` / `note_bodies` with their columns), GIN(tags_hmac) (wave 1), v5's 9 flat partials + GIN (deferred, 2.6). `BackfillCrdtHead.enqueue_all` uses `note_bodies_head_missing (note_id) WHERE crdt_head IS NULL` instead.

Survivors of today's 18 (+3 wave 1, +10 v5): **11**. Index entries a live note carries: 7 (pkey, feed, path_live, basename, path_ci, folder, type if typed) vs 13 today.

Entry sizes (btree leaf: 8 B header + key aligned to 8 + 4 B line pointer) [est]:

| index | today | target |
|---|---|---|
| path | (user, vault, path_hmac bytea33) 84 B | (vault, path_id) 44 B |
| basename | 84 + 92 (two indexes) | 56 (one, with INCLUDE) |
| folder / path_ci / type | 84 / 84 / 44 | 44 / 44 / 44 (type only for 5%) |
| feed / recent / user_updated | 52 / 68 / 36 | 36 / - / - |
| sum per live note | 812 B (model) / 1,390 B (measured, incl. bloat and non-live rows) | 248 B (model) / ~420 B (same bloat factor) |

### 3.2 `note_bodies`, `note_index_state`

| table | index | serves |
|---|---|---|
| note_bodies | pkey (note_id) | every body read/write, FK cascade |
| note_bodies | `note_bodies_head_missing` (note_id) WHERE crdt_head IS NULL | head warmer discovery. Its predicate is `crdt_head`, which the append path flips: acceptable here because note_bodies has 2 indexes, not 13, and the flip happens once per edit session (`crdt_persistence.ex:335-336` only NULLs a non-NULL head) [code] |
| note_index_state | pkey (note_id) | embed reads/stamps, FK cascade |
| note_index_state | `nis_due` (note_id) WHERE (pending OR NOT dense_ok) AND NOT parked | reconcile sweep (replaces `notes_reconcile_due`); empty in steady state |

No index on `user_id` anywhere: the per-user aggregates (points, floor notes, index budget) read counters (4.3), not scans.

### 3.3 `chunks` (target "points" table, see 6.2)

| index | serves | replaces |
|---|---|---|
| pkey (point_id) | search hydrate `point_id = ANY($K)`, orphan sweep membership, reuse lookup `point_id = ANY($planned)` | `chunks_pkey(id)` + `chunks_qdrant_point_id_index` |
| UNIQUE (note_id, position) | per-note ordered reads, similar_to, delete-by-note, FK cascade | same |

Dropped: `chunks_vault_id_index` (readers: avgdl cache miss -> counter, vault purge -> by note batch), `idx_chunks_user` (readers: rare per-user context_hmac clears and v5's count -> counter), v5 `chunks_with_text_user_id_id_index` (readers: DEK rotation / reencode / tenant sweep paging, which can page by `note_id IN (batch)` through the unique index).

Orphan sweep keysets on `point_id` (uuidv5 is random, so it is a full ordered walk, same as today's walk on `id`).

### 3.4 Index writes per hot-path statement, before -> after

Counted as index tuples inserted for a typical live, untyped note (no title/tag change). "Today" is origin/main + wave 1.

| statement | today | after | why |
|---|---|---|---|
| materializing checkpoint, notes UPDATE | 13-15 (non-HOT: seq, updated_at, content_hash, path_nonce) | **7** on notes (non-HOT: seq) + **0** on note_bodies (HOT, pkey only) + 0-2 on note_index_state (only the first content change after an index run) | |
| compaction (crdt only) | 0-14 (HOT only if the page has room; 42.6% of updates move page today [measured]) | 0 (note_bodies HOT, fillfactor 75) | |
| CRDT append head reset (first after a warm) | 0 on main; 13-15 after wave 1 (head is in the crdt_head_missing predicate) | 2 on note_bodies (pkey + head_missing), once per session | |
| crdt_update_log INSERT per keystroke | 4 (pkey, (note_id, inserted_at), user_id, vault_id) | 2 (wave 2 item 5 drops the user/vault FK indexes) | |
| REST push edit | 13-15 | 7 + 0 | also stops re-encrypting the unchanged path (4.1) |
| genesis create | INSERT 13 + UPDATE 13-15 | INSERT 7 (notes) + 1 (bodies) + 1 (index_state) | body written in the INSERT (4.1) |
| embed run, notes | 2-4 UPDATEs, 1 non-HOT (13-15) + 2 HOT-if-room | **0 on notes**; 1 note_index_state UPDATE (1-2 entries) | |
| embed run, chunks, Delta = 1 of 17 | 17 DELETE + 17 INSERT x 5 indexes = 85 | 1 DELETE + 1 INSERT x 2 = 2 (+2 per shifted row) | diff write (4.2) |
| v5 pass per note (~5.2 points) | ~5.2 x 6 indexes + 20-col notes UPDATE + 10 flat partials + note_attrs rows x 6 indexes | ~5.2 x 2 + 1 note_index_state UPDATE | |
| rename | 13-15 + tombstone INSERT 13 | 7 + tombstone INSERT 4 (pkey, feed, path_tomb, tomb_gc) | |

## 4. Call-count reductions per hot path

Round trips (RT) on the current code vs after. Each RT is ~1 ms on prod [measured].

### 4.1 Sync push and checkpoint

| fix | file:line | RT saved | label |
|---|---|---|---|
| Fold the rotation-lock check into `tenant_enter`: `SELECT set_config(...), set_config(...), (SELECT dek_rotation_locked_at FROM users WHERE id = $1)` | `rotation_lock_check.ex:37`, `crdt_checkpoint.ex:143`, `repo.ex:295` | 1 per REST write and per checkpoint | code |
| Fold the seq bump into the write: `WITH s AS (UPDATE vaults SET change_seq = change_seq + 1 WHERE id = $v RETURNING change_seq) UPDATE notes SET seq = (SELECT change_seq FROM s), ... WHERE <fence> RETURNING ...` | `vaults.ex:78-83` at `notes.ex:994,2409`, `crdt_checkpoint.ex:622` | 1 per write; also shortens the vault-row lock to one statement | code |
| Fold the body write into the same statement: `WITH n AS (UPDATE notes ... RETURNING id), b AS (UPDATE note_bodies SET content_ct = $c, crdt_ct = $s FROM n WHERE note_bodies.note_id = n.id), p AS (UPDATE note_index_state SET pending = true FROM n WHERE note_index_state.note_id = n.id AND NOT pending) SELECT ...` (the body update only fires if the fenced notes update matched) | new | 0 extra RT for the split | est |
| Fence the REST update on `crdt_state_nonce`, not the ciphertext bytea | `notes.ex:2518-2526` | 0 RT, but stops shipping and de-TOASTing a KB-MB parameter per edit | code |
| Stop re-encrypting path/folder on content-only writes | `notes.ex:7113-7132`, `crdt_checkpoint.ex:593-601`, `links.ex:122-128` | 0 RT; AES work, WAL, and the HOT-blocking `path_nonce` change | code |
| Move job enqueues and `links_for_note` out of the vault-locked transaction: one NoteCommitted after commit (as the checkpoint does) | `content_commit.ex:24-44` from `notes.ex:713`; `notes_controller.ex:702` | 6-9 statements leave the txn; vault lock window shrinks to 1 statement | code |
| Create: use `INSERT ... RETURNING id` instead of re-fetching by path; merge cap check + counter into `ON CONFLICT DO UPDATE SET notes_count = notes_count + 1 WHERE notes_count < $cap RETURNING` | `notes.ex:997-1002`, `4301`+`1001` | 2 per create (and closes the TOCTOU at `856-860`) | code |
| Merge `classify_by_id` + path lookup into one `WHERE id = $1 OR (vault_id = $v AND path_id = $p AND live)` narrow select | `notes.ex:1530`, `1473/2262` | 1 per create | code |
| Genesis: write content + state in the INSERT; no in-txn checkpoint | `notes.ex:1842-1873`, `crdt_channel.ex:1113-1428` | ~10 of ~21 per first-sync note; 1 notes version instead of 2 | code |
| Checkpoint: read only `content_hash, version, seq, crdt_state_nonce, dek_version, path_ct` for the fence; decrypt content only when history records | `crdt_checkpoint.ex:252-258,434` | 0 RT, one de-TOAST + decrypt per checkpoint | code |
| Skip compaction when `prune_ids == []` and the union equals the stored state | `crdt_checkpoint.ex:568-583` | 6-7 per unbind no-op | code |
| Revisions common path as one `UPDATE ... RETURNING` with fallback | `revisions.ex:112-136` | 1-2 per write with history on | code |

Totals [code + est]: REST edit 15 -> 8 RT (BEGIN, enter+rotation, path lookup, tail read, one CTE write, COMMIT, + after-commit job insert); materializing checkpoint 10 -> 5 (enter folds rotation; one CTE does seq+notes+body+pending+tail delete; NoteCommitted after commit); genesis 21 -> ~8; create 19 -> ~10.

### 4.2 Embed pipeline

| fix | file:line | effect | label |
|---|---|---|---|
| One pre-embed transaction (load + crash stamp + chunk plan) instead of three | `embed_note.ex:121`, `crash_guard.ex:97`, `indexing.ex:1120` | -6 RT | code |
| One commit UPDATE on `note_index_state` with every stamp (`payload_hash`, embed stamps, crash clear, v5 tier/chunk_count/flat fields, `points`), CAS on the indexed content hash | `indexing.ex:408-418`, `embed_note.ex:777-792`, v5 `1109-1133,2773-2781` | 3-6 notes versions -> 1 narrow version | code |
| Diff-write chunks: `DELETE ... WHERE point_id = ANY($stale)`, `INSERT` only new points, one `UPDATE ... FROM unnest(...)` for shifted positions; make `UNIQUE (note_id, position)` DEFERRABLE INITIALLY DEFERRED so shifts cannot collide mid-statement | `indexing.ex:385-390` (v5 `1021-1026`, `2577-2587`) | 34 row ops -> ~2 for Delta=1; v5 stops re-encrypting every point's text per pass | code |
| `points` counter in note_index_state + per-user sum in `usage_meters` (adjusted by the +/- Delta the commit already knows) | v5 `indexing.ex:726-763`, `reconcile_embeddings.ex:507,590`, `billing_controller.ex:76,94` | removes a per-pass `count(*) FROM chunks WHERE user_id` (O(user's chunks)) and the 12x/day cross-tenant GROUP BY | code |
| avgdl from a per-vault `(sum_tokens, n_chunks)` counter row adjusted at commit | `keyword_index/stats.ex:35-58` | removes a full vault chunk heap scan per node per 10 min | code |
| Gate the v5 budget sweep to one tick (`minute < 5`) | v5 `reconcile_embeddings.ex:882` | 12x -> 1x/day | code |
| Gate `stamp_flat_fields` on a hash of the extracted fields | v5 `indexing.ex:2773-2781` | removes a 20-column write + note_attrs delete/reinsert per pass | code |
| One `FOR UPDATE` read at commit instead of two (`content_current!` + `stamp_index_tier`) | v5 `indexing.ex:1083-1133` | -1 RT | code |
| Reconcile: stamp only ids with no pending job | `reconcile_embeddings.ex:173-188` vs `288-291` | no notes write for notes inside the 30 s debounce | code |
| Rename: do not NULL `context_hmac` on every chunk (forces a full re-embed); after v5 the point id does not depend on the path | `indexing.ex:524-535,658-668` | 0 Voyage tokens on rename for unchanged text (check: today the folder is not in `embed_text` since #1621 [code: qdrant-storage plan]) | code |

Embed run totals: ~22 RT -> ~12 (Oban 2, pre txn 4, reservation 1, commit txn 4, ack); notes versions 3-4 -> 0; chunk row ops 2N -> ~2 Delta.

### 4.3 Catch-up pull

| fix | file:line | effect | label |
|---|---|---|---|
| Row-comparison keyset `(seq, id) > ($s, $i)` (PG uses it as an index range after the `vault_id` equality) | `notes.ex:4372`, `attachments.ex:1286` | each page reads its page, not the vault from seq 0: O(N^2) -> O(N) for a first sync | code + docs |
| Fold the size probe into the page query (`sum(pg_column_size(b.content_ct)) OVER (ORDER BY seq, id)` in a subquery, cut at the budget) | `notes.ex:4400-4407,4565-4593` | -4 RT per page, one scan instead of two | code |
| Join `note_bodies` for content only; never select `crdt_ct`, index state or hmacs | `notes.ex:4377-4381` | narrower rows (wave 1 already dropped crdt_state) | code |
| Tail reads as a `LATERAL`/`EXISTS` on the page query; skip the empty `IN` refresh | `notes.ex:4631-4737` | -5 RT per 50 live rows | code |

Page of 500: ~62 RT -> ~5 [est]. Page of 100: ~22 -> ~5.

### 4.4 MCP, REST reads, search hydrate

| fix | file:line | effect | label |
|---|---|---|---|
| `get_notes` in one `with_tenant` with `path_id = ANY($ids)` | `handlers.ex:352` | 20 x 4 RT -> 4 | code |
| Narrow selects: `note_exists?` -> `exists?`, `get_note_metadata`, `delete_note_reporting`, `target_query`, `fetch_note_contents`, `Rewriter.current_path`, export `zip_entries`, `fetch_note_by_id(:meta)` for backlinks / channel path reads | see 1.4, 1.7 | no body de-TOAST + decrypt where only id/path is used; with the split most of these never touch `note_bodies` at all | code |
| Room open: drop `note_in_vault?` (bind already rejects), return path from bind | `crdt_channel.ex:2288-2300,2223-2227` | 13 -> 5 RT, two fewer full decrypts | code |
| Hydrate: select `DISTINCT` notes once per search, decrypt per note not per hit, narrow `@note_meta_fields` to id, vault, dek_version, path/title/tags ct | `notes.ex:171-206`, v5 `226-262` | up to 4x fewer decrypts when hits cluster in a note | code |
| REST search: return `c.note_id` from hydrate, drop the per-vault path lookup | `search_controller.ex:167-178` | -(4 x vaults) RT per search | code |
| N+1s -> one query: `release_index_entries.ex:117`, `resolve_moves` `notes.ex:4162`, `apply_moves` `4264` (BulkRename path), marker loops `6326,6448`, enqueue loops `5903,6214` (Oban.insert_all) | | O(N) statements -> O(1) | code |

### 4.5 The tenant envelope itself

`with_tenant` = BEGIN + set_config + COMMIT around every scoped statement: 922k of the ~1.9M statements in 7 days and 1,064 s of client time [measured]. Options, best first:
1. **Fewer transactions per request** (all the folds above). This is where most of the win is.
2. **Fold more into `tenant_enter`** (rotation lock, vault `change_seq` for ETags, the user row the request needs): zero extra RT per item.
3. **SQL functions for the 3-4 hottest single-statement reads** (manifest rows, path lookup, append): a `LANGUAGE sql` function whose first statement is `set_config(..., true)` and whose second is the query runs as ONE extended-protocol statement in an implicit transaction; the local setting is in force for the second statement [docs: SET LOCAL lasts until the end of the (implicit) transaction]. 4 RT -> 1. Needs a security review (role drop inside the function, invoker rights) and EXPLAIN tests; it is not general.
4. Rejected: pinning the tenant on a pooled session (`SET` at checkout, `RESET` at checkin). DBConnection has no checkin hook and a crashed holder can return a connection still scoped to the previous tenant: a cross-tenant read risk at the boundary. Postgrex 0.22.4 has no pipelining API (BEGIN is a fixed simple query, `deps/postgrex/lib/postgrex/protocol.ex:614-618`) [code].

## 5. Bytes

Modelled with PG 18 storage rules (`hyperopt/tuple.py`, `model.py`, `proj.py` next to this file): 32 B tuple header for 9-72 attributes, 4 B line pointer, 8-byte alignment for int8/timestamp, uuid align `c`, 1-byte headers for short varlena, 18 B TOAST pointers; measured bloat/slack factors (heap 1.12-1.25, index 1.2-1.7) applied to model sizes so they reconcile with prod.

### 5.1 Per row

| | today [measured] | v5 as planned [est] | target [est] |
|---|---|---|---|
| notes core heap | 1,529 B (incl. inline small bodies, dead tuples) | +8 B header (79 attributes), +~60 B flat/tier columns on rows that have them | ~600 B (476 B tuple, fillfactor 90 + slack) |
| notes indexes | 1,390 B | + 10 flat partials (small) | ~420 B |
| bodies (content + crdt) | 15.9 KB TOAST | same | same 15.9 KB (moved, not shrunk) + ~150 B heap/pkey |
| index state | in notes | in notes | ~180 B per live note |
| **notes total per row** | **19.1 KB** | ~19.2 KB | **~17.3 KB**; **~9.3 KB** if content is derived from the Y.Doc (5.3) |
| chunk row | 425 B (247 heap + 178 idx) | ~1,750 B (1,356 B inline tuple with two envelopes + 6 indexes) | ~1,400 B (one envelope, 2 indexes); **~180 B** sliced; ~300 B hybrid |
| points per live note | 20.1 | ~5.2 | ~5.2 |
| **chunk bytes per live note** | **8.5 KB** | **~9.1 KB** | 7.3 KB / 0.9 KB sliced / 1.6 KB hybrid |

Note that v5 cuts rows 3.9x but makes each 4x wider, so chunk bytes in Postgres do **not** fall under v5 as planned; they move from Qdrant into Postgres.

### 5.2 100k users (linear from prod, real whale mix)

| | today | v5 as planned | target (one envelope) | target (hybrid slice) | + content from Y.Doc |
|---|---|---|---|---|---|
| notes | 161 GB | 162 GB | 146 GB | 146 GB | 79 GB |
| chunks | 57 GB | 61 GB | 49 GB | 10 GB | 10 GB |
| **total** | **218 GB** | **223 GB** | **195 GB** | **156 GB** | **89 GB** |

Per user at the real percentiles [est, today -> target hybrid]: p50 user (1 note, 5 chunks) ~21 KB -> ~18 KB; p90 (70 notes, 527 chunks) ~1.6 MB -> ~1.3 MB; p99 (1,158 notes, 12.5k chunks) ~27 MB -> ~21 MB (v5's per-note cap does most of the chunk cut for whales).

Sensitivity, "no whales" (100k users who look like prod minus its top 5): notes ~70 GB, chunks today-shape ~11 GB [est]; every ratio above holds.

Not in this table but adjacent, flag for v5: `embedding_cache` (v5 Task 12.1) stores a 2,048 B f16 vector + ~80 B per cached text, PK `(user_id, key)`, `note_id` index, `inserted_at` index. If the v5 pass caches every point it embeds, that is ~34.7M x ~2.2 KB = **~76 GB at 100k, more than notes + chunks after this addendum**, until the 30-day prune. The plan says prune on `last_used_at`; the v5 migration has only `inserted_at` [code: v5 `20261020090000`]. Cache only paid Voyage results that a retry could re-pay (the H5/H9 cases), and prune on hours, not 30 days.

### 5.3 The three byte levers that dominate

1. **Content stored twice** (`content_ct` 7.1 KB + `crdt_state` 7.1 KB avg per row, 95% of notes bytes [measured]). The Y.Doc is the sole authority (identity-as-CRDT decision); `content` is a projection written at checkpoint [code: 10.3 of the audit]. Dropping `content_ct` for notes that have a `crdt_ct`, and materializing text with one yrs decode on read, saves ~67 GB at 100k [est]. Cost: a decode on embed, pull, MCP read and export (yrs decode of a typical doc is sub-millisecond; a 10 MiB doc is the outlier) and a careful rollout (frontmatter-drift and second-lineage classes). Not v5-coupled; measure decode p50/p99 in the NIF first.
2. **Chunk text** (2.4b): 37-40 GB of v5's plan at 100k vs ~1.5-4 GB with slicing/hybrid [est]. v5-coupled: decide before PR-11.
3. **Tombstones and rename tombstones keep bodies** (wave 2 item 1). 14% of rows today, growing with every rename [measured].

Everything else in this doc is small in bytes (single-digit GB at 100k) but large in write cost and latency.

## 6. Migration path

Constraints: zero operator action (pull + restart), skip-release safe for self-host, rolling-deploy safe (N-1 code runs against the new schema), expand / migrate / contract per AGENTS.md, bulk data moves through the `data_migrations` ledger on `Repo.maintenance()` in id-ranged batches (never the `NO FORCE ROW LEVEL SECURITY` + whole-table UPDATE pattern, which holds ACCESS EXCLUSIVE), every new tenant table gets RLS + FORCE + `maintenance_all` + grants.

### 6.1 Ordering relative to v5

| step | ships | contents | v5 relation |
|---|---|---|---|
| 0 | now, before PR-11 merges | rename v5 migrations off `20261020120000/120001` (collision with wave 1); remove `20261020120001` (chunks_with_text index), `20261020100001` (flat-field indexes), and move `20261019110000/120000/20261020100000` columns (index_tier, chunk_count, flat fields) to `note_index_state` | edits unmerged v5 migrations, so no immutability issue |
| 1 (expand) | with PR-9/PR-11 | create `note_index_state`, `note_bodies`, `points` (6.2); dual-write: every content writer writes `notes` columns AND `note_bodies`; every stamp writer writes both; v5 writers write only the new tables for new columns | v5 code targets the new tables from day one |
| 1b (migrate) | same release | ledger `note_split_v1`: copy `notes` -> `note_bodies` / `note_index_state` in id batches (maintenance pool; per tenant via `TenantScan` on self-host). Done = no note without a body/state row whose `seq` is behind. Idempotent, resumable, re-runs while N-1 nodes write | zero Voyage: `pending = (embed_hash IS DISTINCT FROM content_hash)` is copied, never recomputed. A missing state row must read as "unknown, copy first", **never** as "due", or reconcile would re-embed every note |
| 2 (switch reads) | next release | readers use bodies/state, gated at runtime on `DataMigrations.done?("note_split_v1")` with the old columns as the fallback, so a skip-release self-host jumping from step 0 to 2 still reads correctly while its ledger runs | v5 pass (PR-16/17) runs after this, so it reads and writes only the new layout |
| 3 (contract writes) | release after 2 | stop writing the old `notes` columns; ledger nulls `content_ciphertext`/`crdt_state_ciphertext` on `notes` in batches (frees ~95% of today's notes bytes as dead TOAST that autovacuum reclaims) | after the v5 pass is done |
| 4 (drop) | release after 3 | `ALTER TABLE ... DROP COLUMN` (metadata only), drop the old indexes CONCURRENTLY | with PR-18 |

New `notes` columns (`path_id` etc., `is_folder`, `link_keys_v`, bytea hashes) follow the same pattern: add nullable, dual-write, ledger backfill (pure function of existing columns: truncate the HMAC, decode the hex), `CREATE UNIQUE INDEX CONCURRENTLY` on the new key, switch readers, then drop the old column and index. These are **not** v5-coupled (no Voyage, no Qdrant) and can ship any release; they only need the HMAC keys the server already has.

Attribute count: `notes` stays under 73 attributes through the whole sequence only if v5's 22 `notes` columns never land there (55 today + ~12 new typed columns = 67) [code]. Dropped columns keep counting until a table rewrite, so this is decided once.

### 6.2 `chunks` -> a new `points` table, written once by the v5 pass

The v5 pass rewrites every row anyway ("rechunk once"), so do not ALTER `chunks` in place (type changes rewrite the table under ACCESS EXCLUSIVE; dropped columns leave their attribute slots). Instead:
- Create `points` with the 2.4 layout (PK `point_id`, 2 indexes, no `id`/`vault_id`/`created_at`/`heading_path`, one `display_ct`, `member_fps bytea`, int4 `token_count`) in step 1.
- Every v5-layout writer (v5 plan 15.1; the only writer since the `:write_v5_layout` flag was removed, engram-app/Engram#2253) writes `points`; v3 writers keep writing `chunks`.
- Readers (hydrate, reuse, delete, repath, orphan sweep, budget) read `points` first, then `chunks` (v5 already has dual-format readers for payload and text: Tasks 11.3, 15.4).
- When `IndexVersions.done?` and `chunks` is empty for live notes, PR-18 drops `chunks`. No backfill, no rewrite, no lock.
- Self-host on an older Qdrant (no v5 layout) keeps `chunks` until its own pass; the gate is the same `done?`.

### 6.3 Rolling-deploy and self-host checks

- N-1 nodes during step 1 do not dual-write; the ledger's "done" predicate is a comparison (`note_bodies.seq_at_copy >= notes.seq` or equivalent), so it keeps re-copying rows those nodes touched until the deploy settles.
- Readers switch only in step 2, a later release, so no reader ever sees a body older than its notes row (never switch reads and stop writes in one release: `docs/context/migrate-data-rollback-trap.md`).
- Single-node self-host has no rolling window; skip-release installs carry dual-write + ledger + gated reads in every release until step 4.
- FK cascades from `notes` delete bodies, state and points, so `CleanupVault`'s batched delete (wave 1) keeps working unchanged.

## 7. Ranked list

Score = gain / effort. Gain uses section 4 RT and section 5 bytes at 100k. Effort: S (< 1 day), M (days), L (a week+). "v5" = must be decided or built inside the v5 rebuild; "now" = independent, ship any release.

| rank | item | gain | effort | when | label |
|---|---|---|---|---|---|
| 1 | Rename v5 migrations off `20261020120000/1` | unblocks merges | S | v5 (now) | code |
| 2 | Catch-up keyset as row comparison `(seq, id) > (...)` (notes + attachments) | first sync O(N^2) -> O(N); every page | S | now | code |
| 3 | Chunks diff-write (delete stale ids, insert new, unnest shift update, deferrable unique) | 85 -> 2 index inserts per Delta=1 edit; v5 stops rewriting every text per pass | M | v5 | code |
| 4 | Do not create v5's 9 flat-field partial indexes + GIN, nor the chunks_with_text index; defer to #2083 | ~11 indexes off the hottest tables, no HOT blocking | S | v5 | code |
| 5 | Move v5's 22 new columns (index_tier, chunk_count, flat fields, rebuild_paid_at) to `note_index_state` | indexer never writes `notes`; keeps notes under 73 attributes (-8 B per version) | M | v5 | code |
| 6 | Chunk text: hybrid slice from content (store `display_ct` only for big notes), else at least one envelope instead of two | ~37-40 GB -> ~4 GB at 100k (hybrid); ~6 GB saved with one envelope alone | M | v5 (before PR-11) | est |
| 7 | Points / avgdl counters instead of `count(*)`/`avg` over chunks; gate the 04:00 sweep to one tick | removes per-pass O(user chunks) count, 12x/day full GROUP BY, per-node vault heap scans | S-M | v5 | code |
| 8 | Seq bump + body + pending + tail delete folded into one CTE write; rotation check folded into `tenant_enter` | REST edit 15 -> 8 RT, checkpoint 10 -> 5 RT, vault lock = 1 statement | M | now | code |
| 9 | Genesis writes the body in the INSERT (no in-txn checkpoint) | first-sync create ~21 -> ~8 RT, 2 -> 1 notes versions | M | now | code |
| 10 | Stop re-encrypting path/folder on content-only writes; fence REST on `crdt_state_nonce` | no AES/WAL churn, no HOT-blocking nonce change, no MB bind params | S | now | code |
| 11 | `note_index_state` + `pending` CAS; embed stamps leave `notes` | 3-4 notes versions per embed run -> 0; reconcile reads a tiny partial index | M-L | v5 | code |
| 12 | `points` table with PK = point_id, drop id/vault_id/created_at/heading_path/user FK+index; `context_hmac` dropped after the pass | 5 (6) chunk indexes -> 2; ~100 B less per row | M | v5 | code |
| 13 | `note_bodies` split (content + crdt + head out of `notes`) | notes heap 1.5 KB -> ~0.6 KB/row; checkpoint bodies HOT; manifest/tree/link scans read ~3x fewer pages | L | v5 window (shares its migration steps) | est |
| 14 | Pre-embed and commit transactions folded; one commit UPDATE | embed ~22 -> ~12 RT | S-M | v5 | code |
| 15 | Catch-up: probe folded into the page; lateral tail; skip empty refresh | page of 500 ~62 -> ~5 RT | M | now | code |
| 16 | `(vault_id, ...)` leading keys, 128-bit HMACs as uuid, partial-on-live indexes, merged basename+length, feed serves recent | notes index entries 13 -> 7 per live note; ~1.4 KB -> ~0.4 KB/row | M | now (ledger backfill) | est |
| 17 | MCP `get_notes` in one transaction with `ANY`; room open 13 -> 5 RT; hydrate decrypt per note; REST search drops the per-vault lookup | 80 -> 4 RT per get_notes; ~8 RT per room open | S | now | code |
| 18 | Narrow selects everywhere a full row is read for id/path (1.4, 1.7 list) | no body de-TOAST/decrypt on ~10 paths | S | now | code |
| 19 | N+1 loops -> one statement (release_index_entries, resolve/apply_moves, marker and enqueue loops) | O(N) -> O(1) statements | S-M | now | code |
| 20 | Drop dead/side-effect indexes: created_rank, fm_created, fm_timestamp, type -> partial (wave 2 has most) | fewer writes, planner stops picking them | S | wave 2 | measured |
| 21 | Content derived from the Y.Doc for CRDT-bearing notes | ~67 GB at 100k (the largest byte lever) | L | after v5, owner decision | est |
| 22 | `embedding_cache` sizing (cache only re-payable results, short TTL, `last_used_at`) | avoids ~76 GB transient at 100k | S | v5 | est |
| 23 | Folder ciphertext only on folder rows; `title_ct` NULL when it equals basename; nonce merged into ct; one metadata envelope | ~70 + ~58 + ~10 + ~60 B per note | M | with item 16 | est/measured |
| 24 | Small types: hex -> bytea (content_hash, crdt_head), int8 -> int2/int4, `kind` -> bool, `link_keys_stamp` -> smallint, `embed_model` -> smallint, `payload_hash` 16 B, `member_hmacs` -> bytea | ~200 B per note, ~100 B per merged point | S each | with 11/12/16 | measured |
| 25 | SQL-function single-RT reads for manifest / path lookup / append | 4 -> 1 RT on the 3 hottest statements | M + security review | later | est |
| 26 | Compaction no-op skip; checkpoint narrow read; Revisions single statement | 6-7 RT per no-op unbind; one de-TOAST per checkpoint | S | now | code |
| 27 | zstd markdown dictionary; Yjs v2 encoding | est 15-30% on small notes; 5-15% on state | M | later, measure first | est |

Considered and rejected:
- Moving `seq` to a narrow side table so checkpoints are HOT on `notes`: saves ~5 index inserts per checkpoint but adds a join to the feed, recent, manifest and tree; at 18 checkpoints/s projected for 100k users [est from 45.7k/7d x 242] that is not worth the read cost.
- Folder markers in their own table: 11.5% of rows, but every folder code path and a third merged seq feed; small gain.
- Session-pinned tenant (4.5): cross-tenant risk.
- Dropping `crdt_state` for cold notes and re-seeding from content: mints a second lineage (`crdt-frontmatter-reseed-second-lineage.md`), the known data-loss class.
- Deterministic nonces to save 12 B per envelope: nonce-reuse risk under AES-GCM.

Open questions for the owner (each blocks one ranked item):
1. Chunk text in Postgres: hybrid slice (item 6) or keep v5's per-point text?
2. Confirm the v5 UUIDv5 fingerprint is the context fingerprint, so `context_hmac` can go after the pass (item 12).
3. Content-from-Y.Doc (item 21): acceptable after the v5 pass, once the decode cost is measured?
