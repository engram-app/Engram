# Context Doc: Qdrant disk breakdown (prod, 2026-11-24)

_Last verified: 2026-11-24_

## Status
Measured snapshot of prod (`engram-saas-prod-v3`, collection `engram_notes`, 1 shard, 23 segments, ~1.59M points). Numbers age; the method does not.

## What This Is
Where Qdrant disk goes (10.94 GB of file lengths, 9.82 GB actually used), why `/telemetry` cannot explain it, what Postgres holds for comparison, and a projection table for sizing chunker or embedding changes.

## How to measure (the one call that adds up)

`GET /collections/engram_notes/memory` returns per-component `disk_bytes` that **sum to the disk gauge exactly** (10,936,428,339 B vs `engram_prom_ex_qdrant_disk_bytes` 10,936,420,956 B). Use it for the split between components.

Those are **file lengths, not allocated blocks**: Qdrant 1.19.2 `memory_stats.rs` reports `fs_err::metadata(path)?.len()`. Real usage is the volume fill from `/sys_metrics` (`kubelet_volume_stats_used_bytes`): **9.82 GB used of 16.7 GB, including WAL, about 6.15 KB per point**. Used / file-length = 0.897, so scale any `/memory` figure by ~0.9 for real disk.

Do NOT size from `GET /telemetry?details_level=3`. Its `vectors_size_bytes` (4.81 GB) + `payloads_size_bytes` (0.64 GB) leave ~5.5 GB "missing" because telemetry omits: the sparse inverted index, on-disk payload overhead, payload indexes, the quantized copy, and the id tracker.

Grafana: `engram_prom_ex_qdrant_*` gauges are scraped once per ECS task. Use `max by`, never `sum` (see `grafana-qdrant-metrics-per-task.md`).

## Breakdown of 10.94 GB (file lengths; shares are shares of file length)

| Component | Bytes | Share | Notes |
|---|---|---|---|
| Dense storage | 3.43 GB | 31% | Fixed 2,048 B slot (1024 dims x float16) x 1,659,990 slots. ~0.60 GB of that is empty slots: 228,916 keyword-only points + 65,735 deleted points still reserve a dense slot |
| Dense binary quantization | 0.25 GB | 2% | `always_ram` |
| Dense HNSW | 0.03 GB | <1% | `m=0`, only `payload_m=16` per-tenant graphs |
| Sparse vectors (`keyword`) | 2.79 GB | 26% | ~1,682 B/vector, ~9.8 B per non-zero; avg 172 non-zeros, max 1,154 |
| Sparse inverted index | 2.88 GB | 26% | ~10.1 B/posting. Main cause of the telemetry gap |
| Payload | 1.16 GB | 11% | ~696 B/slot on disk vs 364 B JSON avg |
| Payload indexes `u`/`v`/`n` | 0.35 GB | 3% | |
| Id tracker | 0.05 GB | <1% | |

**Keyword search (sparse vectors + inverted index) = 5.67 GB, 52% of disk.** Dense search including quantization is 34%.

Other measured facts:
- 66% of points carry retired payload keys (for example `fa`). A `u`/`v`/`n`-only payload is ~118 B JSON. No chunk text is stored in the payload.
- 4.0% of points are deleted-not-vacuumed overall, max 8.4% in one segment. Live `deleted_threshold` is 0.1 (code default in `lib/engram/vector/qdrant_layout.ex:278` is 0.2; prod overrides via ServiceConfig), so no segment has crossed the vacuum line.
- Only one cluster and one collection exist; no aliases, no leftover collection.

## Postgres for comparison

DB is 12.35 GB (`pg_database_size`), so "Qdrant is almost as big as Postgres" is real, not a measuring error.
- `note_bodies` 3.66 GB: holds `content_ct` (~1.43 GB) and `crdt_ct` (~1.46 GB). Content is zstd-compressed before encryption (`lib/engram/crypto/envelope.ex:16-28`), which is why it is smaller than raw note text.
- `notes` TOAST 2.66 GB is the body columns dropped by migration `20261118100000_drop_notes_body_ciphertext_columns_drops.exs`. A dropped column keeps its bytes until the table is rewritten (VACUUM FULL / pg_repack). It is dead weight, not live data.
- `chunk_points` 1.37 GB, `chunks` 0.74 GB.

## Code facts that set the size

- `native/engram_native/src/chunker.rs:13` `MAX_CHUNK = 2048` bytes (~512 tokens); `:18` `MIN_CHUNK = 512` (smaller sections merge); `:15` `MAX_PREFIX = 512` breadcrumb; `:25` `WINDOW = 1024` content-defined cut window.
- `lib/engram/parsers/markdown.ex:159` `dense_kind?/1`: only prose / frontmatter_dense / canvas_dense chunks get a dense vector; the rest are keyword-only points (but still occupy a dense slot, see above).
- `lib/engram/indexing.ex:3867-3871` upserts `%{"keyword" => sparse}` alone when there is no dense vector.
- `lib/engram/keyword_index/qdrant_sparse.ex:5,26`: sparse indices are `HMAC(user filter key, token)` folded to u32. Keyword data in Qdrant is not plaintext. Moving keyword search to Postgres `tsvector` would store plaintext words and break that property.
- `lib/engram/embedders/voyage.ex:47` default `voyage-4-large`, `:151` `truncation: false`, `:216` `maybe_put_output_dimension`; `lib/engram/embed_models.ex:51` plan defaults. Dims are 1024 (`voyage.ex:56`) and no `output_dtype` is sent, so vectors arrive as float and are stored float16.

## Projection table (derived arithmetic, not measured)

File-length GB against today's 10.94. Single-lever rows change one thing each.

| Change | Est. file length |
|---|---|
| Dense 512 dims | ~9.1 GB |
| Chunks 2x larger | ~7.9 GB |
| Chunks 4x larger | ~5.8 GB |
| Drop sparse keyword leg entirely | ~4.4 GB |
| Vacuum / compact deleted + empty slots | ~10.5 GB |
| A: compaction + strip retired payload keys | ~9.8 GB |
| A+B+C+D (compaction + payload strip, int8, 512d, 4,096 B chunks) | 5.0 to 6.4 GB, depending on how much sparse shrinks with bigger chunks (x0.75 to x1.0, assumed; points x0.547 measured 10-19) |

**Floor:** with the keyword leg left as is, the floor is ~5.45 GB (3.8x the 1.43 GB of compressed note content). Any projection below that is wrong. An earlier draft listed "combined ~2.0 GB"; it was below the floor and has been removed.

Lever constraints (measured, do not re-litigate without new evidence):
- **int8 dense is not workable.** Qdrant stores Voyage int8 as uint8 0..255, and binary quantization on top then sets every bit to 1 (measured 2026-10-19). The B step in the combined row is therefore not available as-is.
- **512d needs no re-embed.** Truncating the stored 1024d vectors to 512 gives cosine 0.9999993 against a fresh 512d embed (measured 2026-10-19).
- **Only chunk size needs a re-embed** (one full prod re-embed costs about $58).
- **Sparse uint8 index exists but was rejected.** `SparseCompressedMmapU8` exists, but short posting lists pad to 8 bytes; measured 2026-10-19 at about -101 B per point, not worth it. There is no setting to avoid storing both sparse vectors and the inverted index: `SparseVectorParams` has no storage field in 1.19.2.

Takeaway: dense-side tricks move little because keyword search is half the disk. Chunk size moves both legs but costs a re-embed. Dropping sparse is the biggest single lever but costs keyword search or its encryption property.

## Growth and cost

- v3 cluster went from 308k points (2026-10-26) to 1.596M (2026-11-25). A 612k figure seen in older notes is the old v2 cluster, not v3.
- Organic growth: +16.4k points/day (7-day slope, ~52 MB/day used) or +26.7k/day (14-day slope, ~110 MB/day).
- The disk alert fires about 2027-01-15 (14-day slope) to early March 2027 (7-day slope).
- Cost: mx1 (4 GiB RAM, 16 GiB disk) is $34.08/mo. Disk-only expansion is about $0.445/GiB/mo and **can never be shrunk back**. One full re-embed is about $58.

## Industry context
- Qdrant capacity planning guide: memory ~ points x dims x 4 B x 1.5 (float32 plus overhead).
- Voyage: int8 at 1024d scores ~0.3% below float (voyage-3-large launch blog).
- Chunk size norms are 256-512 tokens (Chroma chunking study); Khoj uses 256 words; Obsidian Copilot ranges from whole note up to 6,000 chars.

## Failed Approaches / Dead Ends
- Sizing from `/telemetry` (undercounts by ~5.5 GB, see above).
- Per-column Postgres sizing in one query: RLS forces a per-tenant loop. `chunk_points` has no `user_id`-leading index, so each per-tenant count is a full-table scan; the loop pushed prod RDS CPU to 41% and was aborted. Use catalog sizes (`pg_total_relation_size`, TOAST size) or add the index before looping.
- Summing the Grafana Qdrant gauges across tasks (reads ~3x).

## References
- Prior decisions: `reports/2026-10-19-rechunk-once/` in the engram-workspace repo (untracked, local only) and `chunker-v5-rebuild.md` on workspace branch `docs/chunker-v5-findings`. Read these before proposing a chunker, dims, dtype or sparse change.
- `docs/context/grafana-qdrant-metrics-per-task.md`
- `docs/context/qdrant-payload-rewrite-churn.md` (why retired payload keys linger)
- `docs/context/index-version-self-heal.md` (changing chunker / keyword encoding safely)
- `lib/engram/vector/qdrant_layout.ex` (collection config)
