# Local dev preview stack (frontend changes vs. real backend)

_Last verified: 2026-05-28_

## Status
Working. How to preview frontend changes against a locally-running backend
without booting against the shared FastRaid Postgres (which fails the boot
canary). Repeatable.

## The problem
Sourcing the repo's `.env.local` as-is points `DATABASE_URL` at the **shared
FastRaid Postgres** (`10.0.20.214:35432`) with `KEY_PROVIDER=local`. Phoenix
then fails to boot:

```
** (RuntimeError) boot canary unwrap failed: :malformed_wrapped_blob via provider local
```

(from `lib/engram/crypto/boot_canary.ex`).

**Root cause:** that shared DB's `system_canaries` row was wrapped with a
different master key than the `ENCRYPTION_MASTER_KEY` in the local `.env.local`
(stale after a master-key rotation / KMS work). The boot canary is a security
guard — **do NOT bypass it.**

## The solution
Stand up a **fresh empty local Postgres** and reuse everything else from
`.env.local`. `Engram.Crypto.BootCanary.verify!/0` auto-provisions a fresh
canary when `system_canaries` is empty (see `boot_canary.ex` ~lines 44-49), so a
brand-new empty DB boots clean under whatever local `ENCRYPTION_MASTER_KEY` is
set — no mismatch.

So the **only** override needed is `DATABASE_URL` → fresh local PG. Reuse the
rest of `.env.local` as-is: Clerk vars, Paddle sandbox vars, shared
`QDRANT_URL` / `OLLAMA_URL` / MinIO, and the same `ENCRYPTION_MASTER_KEY`.

## Steps

### 1. Fresh local Postgres (one-time; `docker start engram-dev-pg` after)
```bash
docker run -d --name engram-dev-pg \
  -e POSTGRES_USER=engram -e POSTGRES_PASSWORD=engram -e POSTGRES_DB=engram \
  -p 55432:5432 postgres:18.4
```

### 2. Backend (Phoenix on :4000)
```bash
set -a; source .env.local; set +a
export DATABASE_URL="postgresql://engram:engram@localhost:55432/engram"
mix ecto.migrate
mix phx.server
```

### 3. Frontend (Vite)
Worktree env files are gitignored, so copy them from the main checkout first:
```bash
cp ../../.env.local .env.local
cp ../../frontend/.env.local frontend/.env.local
```
Append to `frontend/.env.local`:
```
VITE_AUTH_PROVIDER=clerk
VITE_BILLING_ENABLED=true
```
Start Vite (proxies `/api` → `http://localhost:4000` per `vite.config`):
```bash
bunx vite --host 0.0.0.0 --port 5174
```
Use a non-default port if `:5173` is taken by another worktree's stale Vite.

## Gotchas
- **A git worktree does NOT carry gitignored env files** (`.env.local`,
  `frontend/.env.local`). Copy them from the main checkout (step 3).
- **Onboarding gate blocks the vault + `/settings`** when `billing_enabled=true`
  (`PADDLE_API_KEY` set) until the user accepts terms (click through the
  agreement screen) AND has an active subscription. Seed one directly:
  ```bash
  docker exec engram-dev-pg psql -U engram -d engram -c \
  "INSERT INTO subscriptions (user_id, tier, status, current_period_end, paddle_customer_id, paddle_subscription_id, custom_data, created_at, updated_at) VALUES (<user_id>, 'pro', 'active', now() at time zone 'utc' + interval '30 days', 'ctm_dev_seed', 'sub_dev_seed', '{}'::jsonb, now() at time zone 'utc', now() at time zone 'utc');"
  ```
- **Seeded row has FAKE Paddle ids.** Any endpoint that calls Paddle live
  (`GET /api/billing/subscription`, `/transactions`, payment-update-transaction)
  will 404 at Paddle → 502. The DB-only `/api/billing/status` endpoint works
  fine. To exercise the live Paddle-backed UI you need a **real sandbox
  checkout** so the ids are real.

## References
- Boot canary auto-provision: `lib/engram/crypto/boot_canary.ex` (`verify!/0`, ~lines 44-49)
- Dev iteration loop (Phoenix :4000 vs Vite :5173, prod-bundle rebuild): `docs/context/dev-iteration-loop.md`
- Boot-canary / master-key gotcha on a throwaway DB: `docs/context/local-supabase-audit.md` (Gotcha 3)
