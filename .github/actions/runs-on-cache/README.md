# Vendored: `runs-on/cache`

Local copy of [`runs-on/cache`](https://github.com/runs-on/cache) at **v5.0.7**
(SHA `88d90644011a3a9957fd141a106f5a94f9794203`).

## Why vendored

Our ephemeral self-hosted runners re-download every action from
`codeload.github.com` on each job. This action is a fork of `actions/cache` with
the AWS S3 SDK bundled in, so its `dist/` is ~18 MB — the download intermittently
timed out (100 s × 3 retries), making the `Set up job` phase take ~60 s or fail
outright (`prebuild-mix`, `unit-tests`, `lint`, `migration-gates`, `e2e-browser`).
A local `./` action is served straight from the checkout — no network fetch.

## What's here (minimal)

Only the two entry points `.github/workflows/verify.yml` actually uses:

- `./.github/actions/runs-on-cache`         → `action.yml` (restore + save)
- `./.github/actions/runs-on-cache/restore` → `restore/action.yml` (restore-only)

`dist/{restore,save,restore-only}` are the bundles those reference. Dropped from
upstream: the `save/` sub-action + `dist/save-only` (unused by our workflow),
plus `src/`, `__tests__/`, and docs. Behavior is identical — same inputs, same
S3/MinIO backend config via the same env vars.

## Updating

1. `git clone https://github.com/runs-on/cache && git checkout <new-sha>`
2. Copy `action.yml`, `restore/action.yml`, `dist/{restore,save,restore-only}`, `LICENSE`.
3. Bump the SHA/version in this file and the `# vendored …` comments in `verify.yml`.
