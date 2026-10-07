# Retiring a column in phases: the migrate-data rollback trap

_Last verified: 2026-09-30 (vaults.slug retirement, PRs #1797, #1808, #1818)_

## Trigger

You are retiring a column (here: plaintext `vaults.slug`) with the
expand / migrate-data / contract phases, and the migrate-data PR both switches
reads to the new source AND stops writing (or NULLs) the old column.

## Symptom (caught in review, never shipped)

An adversarial review of #1808 found that nulling slugs in the same release that
first switches reads would break 0.36.0, which is both the rollback target and
the release running ALONGSIDE the new one during a rolling ECS deploy:

- every `/v/:slug` lookup 404s (0.36.0 still reads `vaults.slug`),
- delete 500s: 0.36.0's changeset required `slug`, the changeset error hit a
  `case` with no error clause (`CaseClauseError`),
- its daily reconciler (`case vault.slug do ^base -> ...; _ -> suffixed`) sees
  NULL, takes the `_` branch, and permanently id-suffixes every vault URL.

## Root cause

A phase is only safe if the PREVIOUS release still works against the data the
NEW release writes. Switching reads is safe on its own. Stopping writes is safe
on its own once no running or rollback-target release reads the column. Doing
both in one release violates the second condition.

## Rule

Split migrate-data in two:

1. **2a (#1808, 0.37.0):** derive the slug on read, look up by `slug_hmac`,
   STILL WRITE the plaintext column, tolerate NULL when reading.
2. **2b (#1818):** write NULL; the reconciler clears the old column.

Then contract only once 2a is the oldest release anything could roll back to.

Also learned:

- **Trust the current HMAC over the plaintext column.** A rename left the old
  plaintext slug behind; a reconciler that trusted it would have moved the URL.
- **A new required field is required on INSERT only.** `slug_hmac` is required
  in the create changeset, not the update one, so unreconciled rows can still be
  deleted and restored.
- **Contract must not gate on "old column fully NULL".** Undecryptable rows and
  soft-deleted users' rows never clear, so that gate never opens.

## Key code

- `lib/engram/vaults.ex`: `derive_slug/2`, `put_slug`
- `lib/engram/crypto.ex`: `maybe_decrypt_vault_fields/2`

## Verification recipe

- First run: the `vault slugs reconciled` log counts should sum to the vault
  count. Failures log `vault slug reconcile failed`.
- Prod pre-check via the audit bastion, per tenant. `vaults` is FORCE RLS, so a
  plain `count(*)` sees nothing: loop users in a `DO` block, calling
  `set_config('app.current_tenant', id, true)` per user, and count inside.
  Cross-check the total against `pg_stat_user_tables.n_live_tup` for `vaults`.

## Evidence

- #1797 expand (add `slug_hmac`)
- #1808 migrate-data 2a (read switch, keep writing)
- #1818 migrate-data 2b (stop storing plaintext)
- Related: `rls-enforcement-testing-traps.md`, repo root `AGENTS.md` (phase/* labels)
