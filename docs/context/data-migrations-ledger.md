# Data migrations ledger

_Last verified: 2026-10-06_

## The rule

A data migration that must reach existing rows is an `Engram.DataMigration`
module registered in `Engram.Workers.DataMigrationsRunner` `@migrations`. It is
never an operator command and never a one-off rpc (see "Upgrades require zero
operator action" in `AGENTS.md`). The runner is an hourly cron (minute 33, on
the `:maintenance` queue). Each pass runs one bounded slice of work for every
migration whose ledger row is not done. One migration raising does not stop the
others.

## The contract

- `name/0`, `version/0`, `run_pass/0`.
- `run_pass/0` returns `:done` only when it found no work. Errors, users
  skipped mid DEK rotation and jobs still in flight are `:more`.
- `:done` means no row the backfill would process still needs work, checked
  against exactly those rows (the same scan and predicate the worker uses). A
  row the backfill can never fix keeps the migration open. The cost is one
  cheap pass per hour. That is by design: a closed ledger must not hide an
  unfixed row.
- Readers handle every older format. The ledger only saves work, it is not a
  correctness gate.

## Versioning

Bump `version/0` to reopen a migration. `DataMigrations.done?/2` treats a stored
higher version as done, so a rollback to older code does not redo work. Only
`true` is cached (in `:persistent_term`); a done migration never goes back to
not-done without a code change, and a code change restarts the node.

`IndexVersions` is the exception: its `name/0` embeds the chunker, keyword and
embed model versions, so bumping any of them is a new, not-done migration.

## Cross-tenant discovery

Use `DataMigrations.any_row?/1`. Never `skip_tenant_check: true` on the app
pool: FORCE RLS turns that into zero rows and the migration would close early
(#1349). `any_row?/1` uses the maintenance repo when enabled, else one query per
user inside that user's RLS context.

## Jobs without `unique`

If the backfill worker has no `unique` option, guard the enqueue with
`DataMigrations.jobs_in_flight?/1` so a running chain is not duplicated.

## Tests

`DataCase` resets the `done?` cache before every non-async test. A test that
touches `done?` must not be `async: true`, because the cache is node-global.

## Current migrations

| Name | Covers |
|---|---|
| `IndexVersions` | Every content-current note stamped with the current chunker, keyword and embed model versions. `ReconcileEmbeddings` does the rebuild. Once done it drops the version term and skips the keyword scan. |
| `VaultSlugHmac` | Clears plaintext `vaults.slug` after `slug_hmac` / `slug_suffixed` are set. Removed with the contract release that drops the column. |
| `ContentHashHmac` | Legacy 32-char MD5 `content_hash` to HMAC-SHA256, via the `BackfillContentHashHmac` chain. |
| `NoteLinkHmacs` | Rows predating link extraction (#591): NULL `basename_hmac`, no `note_links` edges, via the `BackfillNoteLinks` chain. Done covers a missing `basename_hmac` only. The chain's final links scope has no needs-work predicate, so a discarded last links job is not detected. |

## Not on the ledger, and why

- `BackfillCrdtHead`: a continuing self-heal. Any `crdt_state` write NULLs
  `crdt_head`, so there is never a final "done".
- `BackfillCrdtState`: a repair tool that must not run unsupervised
  (`user_dek_rotation.ex` ~140).
- `ReindexKeyword`: an operator tool. `IndexVersions` covers keyword-version
  changes.

## Next user

The envelope format backfill (#1872 PR 3).
