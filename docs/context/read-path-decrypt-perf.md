Title: Read-path decrypt performance — parallel decrypt economics, test-DB PG18 requirement, manifest indexing

_Last verified: 2026-06-12 (discovered during PR #530, `perf/read-path-decrypt-batching`)_

## Local test DB now requires PostgreSQL 18 on port 5433

Since the PG18 + UUIDv7 PK rework (PR #524, see `pg18-uuidv7-prod-crashloop-2026-06-11.md`), `mix test` against the default `localhost:5432` (the old `backend-postgres-1` container) fails massively.

| Symptom | Cause |
|---------|-------|
| ~1631 test failures: `Postgrex expected an integer ... got <<16-byte uuid binary>>` | Stale bigint-PK schema in the old 5432 DB; schemas now declare `Ecto.UUID` PKs |
| Migrations fail: `unrecognized configuration parameter "transaction_timeout"` | `transaction_timeout` is PG17+; the 5432 container is older |

Fix:

```bash
export DATABASE_URL=postgres://engram:engram@localhost:5433/engram_test  # engram-dev-postgres, postgres:18.4
MIX_ENV=test mix ecto.drop && MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
```

## Parallel decrypt economics (benchmarked, 10 schedulers)

`Crypto.parallel_map/2` — chunked `Task.async_stream`, one chunk per scheduler, ≤32 items run inline.

- 1k × 50KB payloads: **3.6× faster** than sequential.
- 1k × 5KB payloads: **1.9× faster**.
- 10k × 120B (path-sized) payloads: **SLOWER than sequential** — copying results back to the caller heap rivals the AES-GCM work itself (~4µs/path).

**Rule: parallelize content-sized decrypt batches; keep path/HMAC-sized loops sequential.** Don't "fix" the sequential path loops by parallelizing them.

Why fan-out is cheap on the input side: ciphertexts are refc binaries, so they aren't copied to worker heaps. Workers self-mark `:sensitive` via `get_dek` (T3.3/M9), preserving the DEK-hygiene invariant.

## Manifest query needs no extra index

The partial unique index `(user_id, vault_id, path_hmac) WHERE deleted_at IS NULL` already serves the manifest access path. `kind = 'note'` is non-selective (~all rows), so an extra `(user_id, vault_id, kind)` index is pure write amplification with zero read win. **Don't re-propose it.** Revisit only if `[:engram, :crypto, :decrypt_batch]` / repo query telemetry shows manifest DB time hot.

## Telemetry to check before optimizing further

Registered in PromEx, flows to Grafana:

- `engram.crypto.dek_cache.count` — tagged by outcome (hit/miss)
- `engram.crypto.decrypt_batch.duration_us` + `.count` — tagged `kind` (`:notes` | `:manifest_notes` | `:manifest_attachments`)

Check these before adding more read-path optimization.

## Gotchas

- **Worktree deps can still be stale.** The `.githooks/post-checkout` hook hardlinks `deps/_build/node_modules` from the main checkout, but if the main checkout's lockfiles are stale vs `origin/main` you still need `mix deps.get` / `bun install` in the worktree. Hit both this session: `uuidv7` hex dep missing, `@headless-tree/*` node modules missing.

## References

- PR #530 (`perf/read-path-decrypt-batching`)
- `docs/context/pg18-uuidv7-prod-crashloop-2026-06-11.md` — why the schema is wreck-and-recreate
- `docs/context/encryption-operations.md` — DEK/crypto invariants (T3.x)
