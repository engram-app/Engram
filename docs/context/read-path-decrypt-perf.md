# Read-path decrypt performance: parallel decrypt economics, manifest indexing

_Last verified: 2026-10-03 (first measured in PR #530)_

## Parallel decrypt economics (benchmarked, 10 schedulers)

`Crypto.parallel_map/2` — chunked `Task.async_stream`, one chunk per scheduler, ≤32 items run inline.

- 1k × 50KB payloads: **3.6× faster** than sequential.
- 1k × 5KB payloads: **1.9× faster**.
- 10k × 120B (path-sized) payloads: **SLOWER than sequential** — copying results back to the caller heap rivals the AES-GCM work itself (~4µs/path).

**Rule: parallelize content-sized decrypt batches; keep path/HMAC-sized loops sequential.** Don't "fix" the sequential path loops by parallelizing them.

Why fan-out is cheap on the input side: ciphertexts are refc binaries, so they aren't copied to worker heaps. Workers self-mark `:sensitive` via `get_dek` (T3.3/M9), preserving the DEK-hygiene invariant.

Catch-up pages (`Notes.list_changes_by_seq`) decrypt serially by design: the page is plaintext-budget bounded (~4 MB), so parallel fan-out buys little and would break stop-at-budget. They emit one `decrypt_batch` event per page (`kind: :notes`), like the parallel list callers.

## Manifest query needs no extra index

The partial unique index `(user_id, vault_id, path_hmac) WHERE deleted_at IS NULL` already serves the manifest access path. `kind = 'note'` is non-selective (~all rows), so an extra `(user_id, vault_id, kind)` index is pure write amplification with zero read win. **Don't re-propose it.** Revisit only if `[:engram, :crypto, :decrypt_batch]` / repo query telemetry shows manifest DB time hot.

## Telemetry to check before optimizing further

Registered in PromEx, flows to Grafana:

- `engram.crypto.dek_cache.count` — tagged by outcome (hit/miss)
- `engram.crypto.decrypt_batch.duration_us` + `.count`, tagged `kind` (`:notes`, `:attachments`, `:vault_tree_notes`, `:manifest_notes`, `:manifest_attachments`)

Check these before adding more read-path optimization.

## References

- PR #530 (`perf/read-path-decrypt-batching`)
- `docs/context/encryption-operations.md` — DEK/crypto invariants (T3.x)
