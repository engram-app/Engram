# Embed cost metrics (Voyage tokens by tier, model, trigger)

Use when asking "who is spending Voyage tokens, and why". Complements the
per-user audit in the workspace repo's `docs/context/embed-spend-audit-recipe.md`
(that one reads Postgres; these are fleet-wide Prometheus series, no tenant ids).

| Metric | Labels | Meaning |
|---|---|---|
| `engram_prom_ex_voyage_embed_tokens_total` | `purpose, model, tier, trigger` | Billed tokens. `tier` = `free\|paid\|none`; `trigger` = `edit\|rebuild\|upgrade\|retry\|reconcile\|none` (`none` = outside an indexing pass, e.g. search queries). |
| `engram_prom_ex_voyage_embed_tokens_per_chunk_bucket` | `purpose, model, le` | Histogram, one observation per Voyage request: tokens / texts. Fixed buckets 25..8000. |
| `engram_prom_ex_indexing_chunks_total` | `outcome` | Chunks per committed pass: `embedded` (new point built) or `reused` (kept in place). |

Old `sum by (purpose)` queries still work: the new labels only split series.

```promql
# tokens by tier / model / trigger (indexing only)
sum by (tier, model, trigger) (increase(engram_prom_ex_voyage_embed_tokens_total{purpose="index"}[$__range]))

# reuse ratio (higher = more edits cost nothing)
sum(increase(engram_prom_ex_indexing_chunks_total{outcome="reused"}[$__range]))
  / sum(increase(engram_prom_ex_indexing_chunks_total[$__range]))

# median tokens per chunk
histogram_quantile(0.5, sum by (le) (rate(engram_prom_ex_voyage_embed_tokens_per_chunk_bucket{purpose="index"}[$__rate_interval])))
```

Caveats: `embedded` counts new points including sparse-only ones (no Voyage
cost), so the ratio is a chunk ratio, not a token ratio; use the token counter
for money. `trigger=retry` is a re-attempt of an Oban job, `reconcile` is
backfill-priority work (sweeps, key rotation).
