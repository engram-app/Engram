# Context Doc: Web DB pool starvation from a vault-lock convoy (2026-10-31)

_Last verified: 2026-10-31_

## Status
Mitigation in flight: Engram PR 2356 (SeqGate), plugin PR 671 (batch deletes), load script PR 2357, plus a lock-discipline PR still to come. Not yet on prod.

## When to read this
ALB 5xx with auth/onboarding queries failing `DBConnection ... dropped from queue`, one tenant's burst taking everyone down, or someone proposes raising `pool_size` / PgBouncer / RDS Proxy as the fix.

## Root cause (prod, 2026-10-31 06:47Z)
- One Obsidian client deleted a folder of ~407-533 jpgs. Plugin `main.ts:1003` calls `handleDelete` once per file, not awaited, no concurrency limit.
- Each `DELETE /api/attachments` opened its own `Repo.with_tenant` transaction and called `Vaults.next_seq!/1` (`vaults.ex:87`), which row-locks `vaults.change_seq` until commit. Waiters each hold a pool connection (web `POOL_SIZE` 10).
- Unrelated requests (auth `billing.ex:557`, onboarding `onboarding.ex:938`) could not check out a connection and died with "dropped from queue". Trace: `queue_time` 1.16 s; the vault UPDATE took 82.5 ms vs ~1 ms normally.
- Existing limits count requests only (PreAuthRateLimit 600/60 s; RequireApiRpsBudget 30 rps, API keys only). Nothing bounds concurrency.

## Fixes
- PR 2356: per-vault in-BEAM SeqGate before the txn; 10 s wait, then BusyError -> 429 + `retry-after: 2`. Review caveat: it degrades open after 15 s, so a sustained burst releases all waiters at once; MCP and channel paths are exempt.
- Plugin PR 671: batch attachment deletes via `POST /attachments/batch-delete` (cap 500, one txn, one seq block), honor 429 Retry-After, never park on 429.
- Lock-discipline PR (upcoming) + coalescer: vault note `50 Engineering/_Superpowers Specs/2026-10-31-vault-write-coalescer-design.md`.

## Failed approaches / dead ends
- Raising `pool_size`, PgBouncer, RDS Proxy: the wait is a row lock, not connection count. RDS Proxy would also pin connections on `set_config` (RLS tenant setting).

## Lock order (verified paths)
`vaults` (next_seq / lock_seq) -> `folders` -> notes/attachments rows -> `usage_meters`. Upload is the inversion: advisory locks -> `users FOR SHARE` -> `vaults`, which can deadlock against account delete (`vaults` then `users`). Folder delete/restore, batch move and batch attachment move all take the vault first (consistent). Other sites with the same single-write-takes-vault-lock pattern: note rename/delete, attachment move, MCP section edits/appends, folder rename (encrypt before `next_seq!`), notes batch delete/move with no 500-id cap.

## Staging does NOT reproduce the errors
- Staging Postgres is on the same host (no network hop): ~450 deletes/s, queue drains in ~1.5 s, nothing dropped. Prod RDS pays a round trip per statement inside the lock.
- Loki and Tempo hold only `env=prod`; staging server evidence comes from `docker logs`.
- Measure pool-using endpoint latency instead: `/vaults` and `/health/deep` p99 went 28 ms -> ~1.5 s during a 400-delete burst. `/health` (no DB) is the flat control. `GET /me` never touches the pool (cached), so it is a useless probe.
- Script: `e2e/load/attachment_delete_burst.py` (PR 2357). Needs raw sockets for a 400-concurrency burst from the dev box (httpx is CPU-bound client-side), and a ~61 s wait after seeding or the 600/60 s limiter 429s half the deletes.

## References
- Reports (session scratchpad, may be gone): `audit-db-code.md`, `audit-db-telemetry.md`, `bulk-write-best-practice.md`, `repro-before.md`.
- Pool sizing and connection budget: workspace `docs/context/prod-db-connection-budget.md` (updated in workspace PR 269).
- Related RDS memory regression and blind alerts: engram-infra `docs/context/rds-cloudwatch-dimension-blind-alerts.md`.
