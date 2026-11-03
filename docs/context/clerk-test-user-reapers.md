# Clerk test-user reapers: which instance each one cleans

_Last verified: 2026-11-02_

Two non-prod Clerk instances collect throwaway accounts. Each has its own
reaper and its own secret. A reaper only cleans the instance its key points at.

| Instance | Used by | GitHub secret | Reaper |
|----------|---------|---------------|--------|
| `capital-chipmunk-29` | CI e2e | `E2E_CLERK_SECRET_KEY` | `cleanup_clerk_users.py --target ci` |
| `key-longhorn-79` | staging + local saas-dev | `STAGING_CLERK_SECRET_KEY` | `cleanup_clerk_users.py --target staging` |

`STAGING_CLERK_SECRET_KEY` is sourced from `clerk_secret_key` in engram-infra
`secrets/staging-fastraid.enc.yaml` and wired as a GitHub secret by
engram-infra PR #1728.

## The two targets (`e2e/scripts/cleanup_clerk_users.py`)

- `--target ci` (default): deletes users matching the `e2e-` rule, older than
  1h. Runs from `cron.yml` (`e2e-orphans`) and from `verify.yml`.
- `--target staging`: deletes an account only when EVERY email contains
  `+clerk_test@` and it is older than the `--older-than` value, which must be
  at least 1d. Refuses keys that are not `sk_test_`. More than 100 matches
  fails the run with nothing deleted. Runs from the `staging-clerk-reap` job in
  `cron.yml` (PR #2383).

## Rule for agents

Any ad-hoc test account you create on staging or saas-dev must use a
`+clerk_test@` email (for example `you+clerk_test@example.com`). Anything else
is invisible to the reaper and lives forever.

## Gotcha 1: a green reaper says nothing about an instance it never touches

Staging grew to 62 users because the only reaper ran with the CI key and only
matched `e2e-`. It was green every night while staging leaked. Before trusting
a cleanup job, check which key it loads and which instance that key belongs to.

A one-off prune on 2026-11-02, before the staging reaper existed, removed 57
tagged accounts (62 to 5).

## Gotcha 2: `exit 0` on a missing secret skips silently

Steps guarded like this:

```bash
if [ -z "$STAGING_CLERK_SECRET_KEY" ]; then
  echo "not set, skipping." >&2
  exit 0
fi
```

go green when the secret was never created. `STAGING_CLERK_SECRET_KEY` did not
exist at repo, org or environment level, so both `staging-load.yml` and the new
reaper skipped without failing. Check that the secret exists:

```bash
gh secret list -R engram-app/Engram
```

and read the step log for the "skipping" line, not the job status.

## Not Clerk

The `native-deep` cron was red from 2026-10-28 on RustSec advisories, not on
Clerk (#2365, fixed by #2386). A red `cron.yml` run does not mean a reaper
failed; the staging reaper is its own job with no `needs`.
