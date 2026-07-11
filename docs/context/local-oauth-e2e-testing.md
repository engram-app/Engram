# Running the OAuth/Clerk e2e tests locally

_Last verified: 2026-06-27_

The OAuth e2e tests (`test_47_oauth_websocket_live_sync`, `test_48_oauth_reconnect_catchup`)
`skipif` when `E2E_CLERK_SECRET_KEY` is unset, so the default local harness
(`AUTH_PROVIDER=local`) silently skips them — they only run in CI's `e2e-clerk`
job. That means an OAuth-only failure is otherwise a 15-min CI round-trip to
iterate on. You can run them locally instead.

## What they need

1. The backend stack in **Clerk mode**: `AUTH_PROVIDER=clerk` +
   `CLERK_JWKS_URL` / `CLERK_ISSUER` / `CLERK_PUBLISHABLE_KEY` pointing at a real
   Clerk **test** instance (the JWKS is how the backend verifies the JWTs the
   test mints).
2. `E2E_CLERK_SECRET_KEY` for the pytest runner — `helpers/oauth.py`
   `provision_oauth_tokens` calls the Clerk Backend API with it to create a test
   user + device-flow tokens. **It must be the secret of the *same* Clerk
   instance** the backend verifies against, or the JWT check fails. The
   `sk_test_...` value in `engram/.env.local-saasdev` (`CLERK_SECRET_KEY`) works
   — reuse it.

The saas-dev env (`engram/.env.local-saasdev`) already carries a consistent set:
`AUTH_PROVIDER=clerk`, the three `CLERK_*` URLs/keys, and `CLERK_SECRET_KEY`,
all for the `key-longhorn-79.clerk.accounts.dev` test instance.

## Recipe

The `engram-crdt` harness stack normally runs `ci/compose.yml` +
`ci/compose.local.yml` (which **forces** `AUTH_PROVIDER=local`). Swap that
overlay for a Clerk one that mirrors it (keeps the rate-limit + open-registration
overrides) but flips auth:

```yaml
# /tmp/.../compose.clerk.yml
services:
  engram:
    environment:
      AUTH_PROVIDER: clerk
      CLERK_JWKS_URL: ${CLERK_JWKS_URL:-}
      CLERK_ISSUER: ${CLERK_ISSUER:-}
      CLERK_PUBLISHABLE_KEY: ${CLERK_PUBLISHABLE_KEY:-}
      RATE_LIMIT_AUTH_OVERRIDE: "1000"
      PRE_AUTH_RATE_LIMIT_OVERRIDE: "100000"
      ENGRAM_DEFAULT_REGISTRATION_MODE: open
```

Restart just the `engram` service (reuses the built image + pg/minio — no
rebuild, ~1 min). The `CLERK_*` URLs come from the shell env (compose reads
`${CLERK_*}`):

```bash
set -a; source <(grep -E '^CLERK_(JWKS_URL|ISSUER|PUBLISHABLE_KEY)=' \
  ~/documents/code-projects/engram/.env.local-saasdev); \
  source ~/documents/code-projects/engram-diag/.env; set +a
cd <backend worktree>
docker compose --env-file ~/documents/code-projects/engram-diag/.env \
  -f ci/compose.yml -f /tmp/.../compose.clerk.yml -p engram-crdt up -d engram
```

Then run the OAuth test with the secret + clerk provider:

```bash
cd ~/documents/code-projects/engram-crdt-e2e/e2e
export E2E_CLERK_SECRET_KEY=$(grep -E '^CLERK_SECRET_KEY=' \
  ~/documents/code-projects/engram/.env.local-saasdev | cut -d= -f2- | tr -d '"')
E2E_ENABLE_CRDT=true ENGRAM_PLUGIN_SRC=~/documents/code-projects/engram-obsidian-sync \
  ENGRAM_API_URL=http://localhost:8100/api \
  CI_POSTGRES_CONTAINER=engram-crdt-postgres-1 CI_MINIO_CONTAINER=engram-crdt-minio-1 \
  AUTH_PROVIDER=clerk \
  python3 -m pytest tests/test_48_oauth_reconnect_catchup.py -p no:cacheprovider \
  --reruns 0 --timeout=120 -q
```

**Switch back to local mode** afterwards (the non-OAuth tests need it):
`docker compose ... -f ci/compose.yml -f ci/compose.local.yml -p engram-crdt up -d engram`.

## Notes

- Needs outbound network to `api.clerk.com` (token provisioning) + the Clerk
  instance's JWKS host. Pi-hole/local DNS should resolve these fine.
- The Clerk instance only needs internal consistency (mint + verify on the same
  instance); it does **not** have to match CI's `E2E_CLERK_SECRET_KEY` instance.
- This is how `test_48`'s "update-to-existing-note reconnect catch-up" bug was
  pinned and fixed locally instead of via CI (the two test functions split the
  failure: new-note catch-up passed, update-to-existing failed → the pull-path
  re-enroll gap in `src/sync.ts`).
- For the non-OAuth local loop (plain `mix test`, the standard harness), see
  `local-backend-testing.md`.
