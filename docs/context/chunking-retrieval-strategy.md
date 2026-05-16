# Context Doc: Chunking & Retrieval Strategy

_Last verified: 2026-04-03_

## Status
Working — priorities 1-2 in implementation, 3-5 planned.

## What This Is
Layered strategy for chunking notes and retrieving relevant content. Each priority is independent.

## Current State

Heading-aware chunking at ~512 tokens / 50 overlap (approximate, word-based ~4 chars/token — Voyage API handles actual tokenization). Folder-aware context prepended before embedding. Vector-only search.

## Decided Approach (Layered, Each Independent)

| Priority | Strategy | What Changes | Elixir Module |
|----------|---------|-------------|---------------|
| **1** | **Folder-aware context prepending** | Prepend `folder_path > title > heading` to chunk text before embedding. ~35% retrieval failure reduction (Anthropic benchmark). | `Engram.Indexing` |
| **2** | **Structure preservation** | Keep code blocks, bullet lists, and markdown tables as atomic units — never split mid-block. | `Engram.Parsers.Markdown` |
| **3** | **BM25 hybrid search** | Add sparse vectors (Qdrant native) alongside dense vectors. Reciprocal rank fusion. | `Engram.Search`, `Engram.Vector.Qdrant` |
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
- Chunking research (workspace): `../engram-workspace/docs/context/chunking-strategy-research.md`
