# Context Doc: Local Supabase Schema Audit Stack

_Last verified: 2026-05-26_

## Status
Working (throwaway / off-roadmap). The Engram backend does NOT run on Supabase — this is a disposable local stack used only to point Supabase Studio's Security/Performance Advisors at a real copy of the Engram schema.

## What This Is
A local Supabase stack whose Postgres is loaded with the Engram backend schema (via Ecto migrations) + synthetic data, so Supabase Studio's Security and Performance Advisors can flag missing indexes, RLS gaps, unindexed FKs, etc. Disposable DB — never holds real user data.

## Environment
- Host: Claw (Fedora, `10.0.20.172`). CPU is a **Xeon E5-2650 v2 (Ivy Bridge)** — has AVX but **no AVX2** (load-bearing, see Gotcha 1).
- Supabase CLI built from source → `~/.local/bin/supabase`.
- Stack project dir: `~/supabase-engram-audit` (`supabase init` + `supabase start`).
- Backend repo: `engram` (this repo).

## Connection
Default Supabase local ports (Docker-published on `0.0.0.0`):
- **Studio GUI:** `127.0.0.1:54323`
- **Postgres:** `127.0.0.1:54322` — user `postgres`, pass `postgres`, db `postgres`
- **API / Kong:** `54321`

Studio is loopback-only by intent. Reach it via:
- SSH tunnel: `ssh -L 54323:127.0.0.1:54323 claw` then open `http://127.0.0.1:54323`, OR
- Since Docker publishes on `0.0.0.0`, the LAN IP directly: `http://10.0.20.172:54323` (firewalld may need `firewall-cmd --add-port=54323/tcp`).
- Advisors: `/project/default/advisors/security` and `/project/default/advisors/performance`.

## Auth
- Postgres: `postgres`/`postgres` (local default).
- Encryption master key for the Engram app: persisted at `~/supabase-engram-audit/.master_key` (chmod 600). MUST be stable across runs (see Gotcha 3). Pass it as `ENCRYPTION_MASTER_KEY="$(cat ~/supabase-engram-audit/.master_key)"`.

## Key Commands / Patterns

### Build the CLI (one-time, AVX2 workaround)
```bash
# Prebuilt CLI SIGILLs on this host (no AVX2). Build from source with GOAMD64=v1.
# The package lives at apps/cli-go/ in the monorepo; `go install .../cli@TAG` does NOT work.
git clone --branch <TAG> https://github.com/supabase/cli
cd cli/apps/cli-go && GOAMD64=v1 go build -o ~/.local/bin/supabase .
supabase services    # NOT `supabase --version` — that flag doesn't exist
supabase status
```

### Stand up the stack
```bash
mkdir -p ~/supabase-engram-audit && cd ~/supabase-engram-audit
supabase init
supabase start
```

### Load the Engram schema (from the backend repo)
`backend/config/dev.exs` honors `DATABASE_URL`. Point Ecto at the Supabase Postgres:
```bash
cd backend
mix deps.get
DATABASE_URL="postgres://postgres:postgres@127.0.0.1:54322/postgres" mix ecto.migrate
```

### Grant the RLS app role to postgres (see Gotcha 4)
```bash
docker exec supabase_db_supabase-engram-audit \
  psql -U postgres -d postgres -c 'GRANT engram_app TO postgres;'
```

### Seed synthetic data
Use the committed Elixir seed script (NOT raw SQL/CSV — see Gotcha 2):
```bash
cd backend
DATABASE_URL="postgres://postgres:postgres@127.0.0.1:54322/postgres" \
KEY_PROVIDER=local \
ENCRYPTION_MASTER_KEY="$(cat ~/supabase-engram-audit/.master_key)" \
mix run priv/repo/dev_seeds.exs
```
Defaults: 10 users / 2000 notes. Tunable via `SEED_USERS`, `SEED_NOTES_PER_USER`, `SEED_PREFIX`.

### Lifecycle
```bash
supabase stop  --workdir ~/supabase-engram-audit
supabase start --workdir ~/supabase-engram-audit
```

## Failed Approaches / Dead Ends
- **Prebuilt Supabase CLI binary** — SIGILLs with "Illegal instruction" on this host. Root cause: official binary is compiled `GOAMD64=v3` (requires AVX2); the Xeon E5-2650 v2 has AVX but not AVX2. Must build from source with `GOAMD64=v1`.
- **`go install github.com/supabase/cli@TAG`** — fails with "+incompatible / does not contain package". The CLI is a monorepo; the main package is at `apps/cli-go/`. Clone the tag and `cd apps/cli-go && go build` instead.
- **`supabase --version`** — not a valid flag. Use `supabase services` / `supabase status`.
- **Seeding notes via raw SQL / CSV import** — impossible. Plaintext `content`/`title`/`path` columns were DROPPED in the phase-B encryption migrations; only encrypted blobs + HMAC lookup columns remain. You MUST go through the Engram contexts (`Notes.upsert_note/3`, `Vaults.create_vault/2`, `Accounts.find_or_create_by_external_id/2`, `Crypto.ensure_user_dek/1`). That's why `dev_seeds.exs` is Elixir, not CSVs.

## Gotchas
1. **No AVX2 on this CPU** — see Failed Approaches. Build CLI with `GOAMD64=v1`.
2. **Encryption at rest** — notes/vaults are per-user-DEK, AAD-bound AES-GCM with HMAC lookup columns; plaintext columns are gone. Seed only through the app contexts.
3. **Boot canary** — the app boots `BootCanaryGuard`, which wraps/unwraps a canary row in `system_canaries` using `ENCRYPTION_MASTER_KEY`. Seed once with key A then re-run with key B → boot fails: `boot canary unwrap failed: :invalid_wrapping`. Fix: pin ONE stable master key (`~/supabase-engram-audit/.master_key`). If the canary is already wrapped under a lost key on this throwaway DB (no real encrypted data to protect): `DELETE FROM system_canaries;` then re-run.
4. **RLS role grant** — `Repo.with_tenant/2` does `SET LOCAL ROLE engram_app` + `SET LOCAL app.current_tenant`. Supabase's `postgres` user is not a true superuser and isn't a member of `engram_app`, so writes fail with `42501 permission denied to set role "engram_app"`. The `engram_app` role itself already exists (created by the schema baseline `20260602000000_baseline.exs`; the original `20260403000846_add_rls_policies` migration was collapsed into the baseline in #401). Fix: `GRANT engram_app TO postgres;` (run as postgres via the `docker exec ... psql` above).
5. **Embeddings / Oban** — `upsert_note` enqueues Oban `:embed` jobs that would call Voyage AI + Qdrant (external/cloud). `dev_seeds.exs` pauses the `:embed` and `:reindex` queues before inserting, so nothing fires; jobs stay queued in `oban_jobs` (harmless, and realistic queue data for the audit).
6. **Studio is loopback-only** — reach via SSH tunnel or the LAN IP (Docker publishes on `0.0.0.0`); firewalld may need port 54323 opened.

## References
- Seed script: `backend/priv/repo/dev_seeds.exs`
- Dev config honoring `DATABASE_URL`: `backend/config/dev.exs`
- RLS/role setup creating `engram_app`: `backend/priv/repo/migrations/20260602000000_baseline.exs` (the per-migration `20260403000846_add_rls_policies.exs` was collapsed into this baseline in #401)
- Schema/RLS background: `backend/docs/context/database-schema-rls.md`
- Supabase CLI monorepo: https://github.com/supabase/cli (`apps/cli-go/`)
