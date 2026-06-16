# Privacy-Preserving Hybrid Keyword Search (Qdrant Sparse + HMAC)

**Date:** 2026-06-15
**Issue:** #595 (keyword search), #605 (backfill / re-normalize)
**Supersedes:** PR #606 (Postgres `tsvector` approach — to be closed)
**Status:** Design approved, ready for implementation plan

## Problem

Engram has no keyword / full-text search. Content is stored as ciphertext
(`content_ciphertext`, per-user DEK, AES-GCM), so Postgres cannot `LIKE` /
`tsvector` it directly. Retrieval today is vector-only (Qdrant) plus HMAC
exact-match on tags/folder/path. Users expect literal keyword search ("find
the note that says `PADDLE_API_KEY`") — exactly where dense embeddings
face-plant (identifiers, code, exact strings, typos, boolean queries). The
two indexes fail in opposite directions, so we run both (hybrid).

PR #606 implemented this as a Postgres `notes_fts` `tsvector` side table. Two
problems drove a rework:

1. **Security regression.** A `tsvector` is queryable plaintext — `ts_rank`
   needs the tokens in clear, so the table holds a reconstructable bag-of-words
   of every note, protected only by volume (storage-layer) encryption + RLS. A
   DB dump / injection / insider recovers note contents. This contradicts the
   encryption-at-rest posture that `content_ciphertext` establishes.
2. **Multilingual.** Embeddings are multilingual (Voyage). `tsvector` needs a
   per-language config; `simple` throws away stemming; CJK needs `pg_bigm`
   (another RDS allowlist fight). The keyword leg should at least not mangle
   other languages.

A third realization made the rework strictly better than the original plan:
`ts_rank_cd` lacks all three BM25 mechanisms (no IDF, no TF saturation, no
length normalization — see the #595 decision comment). The new approach
delivers **real BM25** on infrastructure we already run, eliminating the
deferred "migrate to Tiger Cloud for true BM25 at scale" roadmap item.

## Approach

Pivot the keyword leg from Postgres `tsvector` to a **Qdrant sparse vector**,
co-located with the existing dense vector on each chunk point, in the same
collection. The stored sparse representation is `{HMAC(user_DEK, token) → BM25
weight}` — keyed per-user, non-dictionary-reversible, no plaintext tokens at
rest. Qdrant runs native server-side hybrid fusion (dense + sparse, RRF) in one
request.

This resolves all three drivers at once:

- **Security:** at rest, Qdrant holds only `{u32: float}` keyed fingerprints —
  not reversible without the user's DEK. Postgres `notes_fts` is deleted, so the
  Postgres posture *improves* vs PR #606.
- **Ranking:** full BM25 (Qdrant adds IDF server-side; we compute TF-saturation
  + length-normalization client-side).
- **Multilingual:** tokenization is ours (server-side, post-decrypt) — Unicode
  segmentation for any space-delimited script, character bigrams for CJK.

### Why Qdrant sparse and not the alternatives

- **Not Postgres `tsvector`** — plaintext index, no real BM25, painful
  multilingual (the three drivers above).
- **Not true BM25 on a separate Postgres (ParadeDB / Tiger Cloud `pg_textsearch`)
  now** — BM25 isn't installable on managed RDS (`shared_preload_libraries`),
  and the cheap "replica" path is invalid for us (it would replicate
  ciphertext). Deferred at scale on a *measured* signal; the Qdrant-sparse
  approach likely removes the need entirely.
- **Not a TEE now** — the only zero-leak option, but heavy (Nitro Enclaves need
  EC2, not Fargate; no persistent enclave storage). Deferred; the design keeps a
  clean enclave seam (see §Security).
- **Qdrant's *built-in* BM25 is unkeyed** — FastEmbed's `Bm25` hashes tokens
  with `abs(mmh3.hash(token))`: not verbatim, but dictionary-reversible (hash a
  wordlist, match). We swap that one step for `HMAC(user_DEK, token)`. Everything
  else is stock Qdrant BM25.

## Architecture

### Collection: named vectors on chunk points

Dense vectors are already **chunk-level** (one Qdrant point per markdown chunk,
from `Indexing.index_note` → `Markdown.parse` → embed each chunk). We convert
the collection from a single unnamed vector to **named vectors**:

```
point (per chunk) = {
  id,
  vector: { "dense": float[1024], "keyword": { indices: u32[], values: f32[] } },
  payload: { user_id, vault_id, path_hmac, text(ciphertext), ... }   # unchanged
}
```

The `keyword` sparse field is configured with `modifier: "idf"`.

**Consequence (accepted): BM25's corpus unit is the chunk, not the note.** IDF =
chunks containing the fingerprint; `avgdl` = average chunk length. For exact-term
search this is fine (find the chunk → map to note), arguably better (more
granular). Edge case: a multi-term query split across a chunk boundary scores
each chunk on its share — mitigated by the dense leg and chunk overlap;
irrelevant for the single-identifier headline case.

This co-location is what enables **native server-side fusion**: both legs query
the same point space, so a chunk matched by both gets a real RRF boost, and the
Elixir-side fusion from #606 (`Search.Rrf`, `fuse_legs`) is **deleted**.

### Module map (behind the existing `KeywordIndex` seam)

| Module | Role | Status |
|---|---|---|
| `Engram.KeywordIndex` (behaviour) | `upsert/1`, `search/3` callbacks | reuse from #606 |
| `Engram.KeywordIndex.QdrantSparse` | adapter: build/query sparse vectors | **new**, replaces `.Postgres` |
| `Engram.KeywordIndex.Tokenizer` | plaintext → tokens | **new** |
| `Engram.KeywordIndex.Bm25` | TF-saturation + length-norm weight (avgdl-parameterized) | **new** |
| `Engram.KeywordIndex.Postgres` | old `tsvector` adapter | **delete** |
| `Engram.Search.Rrf`, `Search.fuse_legs` | app-side fusion | **delete** (Qdrant fuses) |
| `priv/repo/migrations/*_create_notes_fts.exs` + `notes_fts` table | old side table | **delete** (new migration to drop, or recreate-collection path) |

**TEE seam:** all plaintext-touching logic lives in `Tokenizer` + `QdrantSparse`
(index: decrypt → tokenize → HMAC → weight; query: tokenize → HMAC). A future
enclave migration moves these modules inside; nothing else changes.

## Tokenizer

Exact-token, multilingual, CJK — **no stemming** (the vector leg owns
morphology; stemming would fight exact-match precision and reintroduce
per-language complexity).

1. Unicode **NFKC** normalize → **casefold** (lowercase).
2. Segment:
   - **Space-delimited scripts:** Unicode word boundaries (UAX#29). Underscore is
     kept in-token, so `paddle_api_key` stays whole for identifier search.
     Punctuation splits.
   - **CJK ranges** (Han / Hiragana / Katakana / Hangul): emit overlapping
     **character bigrams** (`東京都` → `東京`, `京都`).
3. Output: token list. Same pipeline for index and query (must be identical).

Optional stopword pruning is a RAM optimization only (IDF already down-weights
common terms) and is **out of scope** for v1.

## Sparse vector build (per chunk, in EmbedNote's decrypted pass)

For chunk `D`, per distinct token `t`:

- **dim** = unsigned `u32` from `HMAC(user_DEK, t)` — take the low 32 bits
  directly. **Do not** sign-fold / `abs()` (FastEmbed issue #369 — halves the
  space and creates guaranteed collisions).
- **value** = full BM25 TF term:
  ```
  f(t,D) · (k1 + 1)
  ─────────────────────────────────
  f(t,D) + k1 · (1 − b + b · |D| / avgdl)
  ```
  with `k1 = 1.2`, `b = 0.75`. `f(t,D)` = term count in chunk; `|D|` = chunk
  token count; `avgdl` = per-user average chunk length (§avgdl).
- **Collision** (rare; ~1 expected at 100k distinct terms): sum the colliding
  values — graceful ranking-only degradation, not a correctness failure.

At query time Qdrant applies `modifier: "idf"`, so the final score is
`Σ IDF(t) · value(t)` = real BM25. Because fingerprints are per-user-keyed, a
fingerprint exists only in that user's chunks → **IDF is automatically per-user**
even though Qdrant computes it over the whole collection.

## Read path

`Engram.Search` dispatch by `mode` (from #606):

- **`:hybrid`** (web controller default): one `POST /collections/{c}/points/query`
  with two `prefetch` sub-queries —
  - dense: `using: "dense"`, query = embedded query vector
  - sparse: `using: "keyword"`, query = `{indices, values}` of HMAC'd query tokens (values = 1.0)
  - both carry `filter: { must: [user_id, vault_id] }` (**load-bearing** — the
    sparse inverted index is global; a missing filter leaks across tenants and
    tanks latency)
  - top-level `query: { fusion: "rrf" }`, `limit: candidates`
  Then: decrypt candidates → **rerank fused top-N (Pro-gated)** → rehydrate
  display fields (#590) → return.
- **`:vector`** / **`:keyword`**: single prefetch (one leg). Internal
  `Search.search` default stays `:vector` so the MCP path and existing
  cosine-asserting tests are unchanged. The MCP `mode` param (from the
  unpushed commit) is retained.

**Score contract (unchanged from #606):** hybrid `score` = RRF fused value
(rank-based, ~0.016), not cosine. `mode=vector` and MCP return cosine. Clients
sorting by score are fine; absolute-cosine-threshold clients are not (already
documented).

**Rerank change:** in #606 rerank ran inside the vector leg before fusion. It now
runs on the **fused top-N** so Pro users' rerank also improves keyword-only hits.
Same `§G` gate (`check_feature(user, :reranker_enabled)`), Pro-only.

## avgdl — per-user, re-normalizable

- Per-vault stats: `{chunk_count, total_chunk_len}` → `avgdl = total / count`.
  Stored in a small Postgres row, updated on each index. Cheap counters.
- `Bm25.weight/…` takes `avgdl` as an **injected parameter** — the future-proof
  seam. v1 uses the vault's current per-user avgdl at index time.
- **#605 backfill worker doubles as the re-normalizer:** recompute a vault's
  sparse weights against current avgdl. It also backfills un-indexed notes and is
  the (now likely unnecessary) Tiger-Cloud migration tool. Target-parameterized.
- **Not building** automatic drift-threshold triggering — uncalibratable with
  zero users (would guess a throwaway number). Re-normalization is available
  manually / on a schedule; auto-trigger is deferred until real-vault data exists.

Rationale: per-user avgdl is the quality-correct choice (matches the per-user
IDF; handles user-length diversity). A global constant mis-normalizes as the user
base diversifies. For this exact-keyword, IDF-dominated leg, avgdl precision is
lower-stakes than for prose ranking — so per-user avgdl is "best" without
gold-plating the automation.

## Security posture

**At rest:**

| Store | Data | Reversible to plaintext? |
|---|---|---|
| Postgres | `content_ciphertext` (per-user DEK). `notes_fts` **deleted**. | No |
| Qdrant | dense vector (pre-existing) | Partially (embedding-inversion, pre-existing) |
| Qdrant | sparse `{hmac_u32: weight}` (new) | No — keyed per-user-DEK, not dictionary-reversible |

**Threat model:** hardens **at-rest dump / stolen backup** and
**cloud-provider insider** (Qdrant Cloud). **Live app compromise** is *not*
addressed by any index design — the app holds DEKs and decrypts in memory; this
is the documented **TEE-future axis**.

**Documented accepted leakage (irreducible for any efficient searchable index):**

1. **Term/document-frequency** — Qdrant maintains per-fingerprint DF counts to
   compute IDF; an at-rest observer learns how many chunks contain each keyed
   bucket (frequency analysis). Scoped per-user by the keying; not
   dictionary-reversible. Only a TEE erases it.
2. **Access pattern** — an observer of *live* queries sees which fingerprints are
   queried and which points return. Pre-existing for any searchable index.

**Commitment statement:** *"At rest we store keyed, per-user token fingerprints
and frequency weights — no verbatim text, not reversible without the user's key.
We accept term-frequency leakage as a documented risk; eliminating it requires a
TEE (roadmap)."*

**SOC 2:** no new boundary (Qdrant already in scope as the dense-vector store /
subprocessor). The HMAC path *upholds* the confidentiality story that the
plaintext-`tsvector` would have contradicted. To-dos when SOC 2 is live: update
the data-flow diagram / data inventory to include the sparse index; document the
frequency leak in the risk assessment; the HMAC key is the DEK (already in the
KMS control set).

## Testing (TDD)

- **Tokenizer:** latin, accented (NFKC), CJK bigrams, identifiers
  (`paddle_api_key` whole), casefold, punctuation splitting.
- **HMAC:** determinism, unsigned u32 (no sign-fold), same token under two users
  → different dims (per-user partition).
- **Bm25:** TF saturation (repeats saturate), length normalization (long vs short
  chunk), avgdl parameterization, k1/b defaults.
- **Collision:** two tokens → same u32 → values summed.
- **Hybrid fusion:** Qdrant integration (`:qdrant_integration`) + Bypass-mocked
  `/points/query` with two prefetches + RRF; chunk matched by both legs ranks
  above single-leg matches.
- **Mode isolation:** `:vector` / `:keyword` / `:hybrid` each return the right
  shape; internal default `:vector`; MCP `mode` param.
- **Rerank:** runs on fused top-N; Pro-gated (Free/Starter passthrough).
- **avgdl:** stats update on index; weight uses current per-user avgdl; backfill
  re-normalizes.
- **Encryption assertion:** stored sparse vector is only `{u32: float}` — assert
  no plaintext token strings reach Qdrant; assert non-reversibility (can't
  recover tokens without the DEK).

## Rollout

- **Close / supersede PR #606.** One new PR (per the single-PR rule): collection
  schema → named vectors, `Tokenizer`, `Bm25`, `QdrantSparse` adapter, EmbedNote
  sparse build, hybrid read path, avgdl stats, #605 re-normalize hook, delete the
  Postgres adapter + `Search.Rrf` + `notes_fts` migration.
- **Recreate the Qdrant collection** with named vectors (pre-launch + prod DB is
  destroyable — "no data is sacred"; a wipe + re-sync repopulates via EmbedNote).
  Confirm a fresh-collection migration path and that existing dense points are
  re-indexed.
- **Version floor:** confirm prod and self-host Qdrant ≥ **1.10** (named sparse
  vectors + RRF + IDF modifier). DBSF ≥ 1.11, weighted RRF ≥ 1.17 if we later
  tune fusion.
- **Self-host** (`engram.ax`) uses Qdrant too → the adapter works identically;
  no Postgres fallback adapter needed (full pivot).

## Open items for the implementation plan

- Exact Postgres location of the per-vault `{chunk_count, total_chunk_len}` stats
  (new column on an existing vault/stats row vs. a small dedicated table).
- Whether re-normalization reads a compact per-chunk token-count structure (to
  avoid re-decrypting the corpus) or simply re-runs the decrypt path. Pre-launch,
  re-decrypt via the backfill worker is acceptable; the compact-structure
  optimization is a flag, not a v1 build.
- Confirm Qdrant supports adding a named sparse vector to the existing collection
  via `update_collection`, or whether recreate is required (recreate is fine
  pre-launch).
- Elixir tokenizer implementation choice for UAX#29 / CJK range classification
  (stdlib regex `\p{L}\p{N}` + codepoint-range checks vs. a Unicode library).
