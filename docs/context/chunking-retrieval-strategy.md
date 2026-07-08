# Context Doc: Chunking & Retrieval Strategy

_Last verified: 2026-06-18_

## Status
Working — priorities 1-3 shipped (BM25 hybrid landed in #610), 4-5 planned.

## What This Is
Layered strategy for chunking notes and retrieving relevant content. Each priority is independent.

## Current State

Heading-aware chunking at ~512 tokens (≈2048 chars), no overlap — large sections are sub-chunked at word boundaries with no carry-over (`parsers/markdown.ex` `split_text/2`). Approximate, word-based ~4 chars/token — Voyage API handles actual tokenization. Folder-aware context prepended before embedding. **Hybrid search (dense + BM25 keyword) shipped in #610** — see below.

### Hybrid keyword search (shipped #610)
Per-chunk sparse vectors live alongside the dense vector in the same Qdrant point. Tokens are NOT stored as plaintext: each token is `HMAC(user_DEK, token) → u32` (no plaintext keywords at rest). Real BM25 scoring uses Qdrant's server-side IDF with client-side TF / length-norm; an NFKC + CJK-bigram tokenizer feeds both index and query. The two legs are fused server-side via Reciprocal Rank Fusion (RRF), so the hybrid `score` is an RRF rank score, NOT a cosine similarity. Callers pick a leg via `?mode=` on `GET /api/search`:
- HTTP default (param absent or unrecognized) → `:hybrid` (`search_controller.ex:81`)
- `?mode=vector` → dense only; `?mode=keyword` → BM25 only
- Note the `Engram.Search.search/4` library default is `:vector` (`search.ex:135`) — the HTTP layer overrides it to `:hybrid`.

Modules: `lib/engram/keyword_index/{bm25,qdrant_sparse,tokenizer,stats}.ex`, reindex via `lib/engram/workers/reindex_keyword.ex`, leg dispatch in `lib/engram/search.ex` (`run_legs/4`).

## Decided Approach (Layered, Each Independent)

| Priority | Strategy | What Changes | Elixir Module |
|----------|---------|-------------|---------------|
| **1** | **Folder-aware context prepending** | Prepend `folder_path > title > heading` to chunk text before embedding. ~35% retrieval failure reduction (Anthropic benchmark). | `Engram.Indexing` |
| **2** | **Structure preservation** | Keep code blocks, bullet lists, and markdown tables as atomic units — never split mid-block. | `Engram.Parsers.Markdown` |
| **3** | **BM25 hybrid search** ✅ SHIPPED (#610) | Per-chunk HMAC sparse vectors (Qdrant native) alongside dense vectors. Server-side RRF. `?mode=` dispatch. | `Engram.Search`, `Engram.KeywordIndex.*` |
| **4** | **Chunk size benchmarking** | Test 256 vs 512 vs 1024 on real data. | `Engram.Parsers.Markdown` |
| **5** | **Parent-child retrieval** | Small chunks for precision, return parent section for context. | `Engram.Search`, `Engram.Vector.Qdrant` |

## Folder-Aware Context Format

```
Knowledge > Health > Blood Work | Iron Panel > Ferritin

Ferritin levels between 30-300 ng/mL are considered normal...
```

## Rejected Strategies

| Strategy | Why Rejected |
|----------|-------------|
| **Semantic chunking** | NAACL 2025 shows fixed-size matches or beats it. Heading structure provides natural boundaries. Extra embedding cost. |
| **voyage-context-3** | Voyage 3 gen, incompatible with Voyage 4 shared space, 50% more expensive, kills tiered product. |
| **Late chunking (Jina)** | Requires Jina-specific models, incompatible with Voyage. |
| **LLM-based chunking** | $50-$1,250 to re-index 5K notes. Every edit triggers LLM calls. |

## References
- Markdown parser: `lib/engram/parsers/markdown.ex`
- Indexing pipeline: `lib/engram/indexing.ex`
