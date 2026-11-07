# Rollback floor

_Last verified: 2026-11-07_

When to read this: shipping a change an older release cannot read (a write stop, a contract migration), rolling prod back, or raising the floor.

## What it is

The rollback floor is the oldest release prod may run. It is one line in `priv/release_floor` (`release-vX.Y.Z`, today `release-v0.76.0`), the single source of truth for `Engram.Release.Floor` and for both deploy checks below.

- **Raising the floor** is a PR changing that line (and the pin in `test/engram/release/floor_test.exs`). It is Todd's decision, because it removes rollback targets. The tag must exist first: the floor names a released tag, never a commit on main.
- **Code that needs a floor** states it with a test, `assert Floor.at_least?("release-vX.Y.Z")`. That test is red while the file says less, so the code cannot merge before the floor is raised. Example: R9 release E's note folder hash write stop needs the floor at the release that ships C, because 0.76 matches folder search by the hash and 0.78.1 matches folder deletes by it.
- **Nothing reads the floor at runtime.** A self-host install that jumps several releases is made correct by each release's own runtime gates (data-migration ledgers, fleet gates). The floor only limits where prod may be rolled back to. A self-hoster downgrading below it is unsupported.

## The checks

1. **engram-infra `engram-rollback-floor.yml` (the real gate, report-only today).** It runs on every engram-infra PR that moves an Engram image pin (the prod bump PR, rollbacks included, and the staging bump PR). It fails unless each pinned commit descends from the floor tag in this repo's main. Details and the image-path table are in engram-infra `docs/context/engram-rollback-floor.md`. Making it a required check is a ruleset change, an owner decision.
2. **`deploy-prod.yml` `release-floor-gate` (defense in depth).** It reads the floor from `origin/main:priv/release_floor`, never from the tagged commit (an old commit carries an older floor), and runs `scripts/check_release_floor.sh`, which fails closed. **It cannot stop a rollback to a commit from before this job existed:** a tag push runs the deploy-prod.yml OF THE TAGGED COMMIT, and that file has no floor step. That is why the engram-infra check exists.

## Incident override

- deploy-prod: an annotated tag whose message contains `[allow-below-floor]`, the `[skip-release-e2e]` pattern:
  `git tag -a release-vX.Y.Z -m "[allow-below-floor] incident: <reason>" <sha>`
- engram-infra: the `allow-below-floor` label on the bump PR.

Both pass with a `::warning::` and a step-summary line. Below the floor, the old code may misread data newer releases wrote (that is what the floor records), so the incident notes must say why.

## Tests

`test/scripts/check_release_floor_test.sh` (verify.yml static checks): a descendant passes; a pre-floor commit and a commit off a pre-floor branch fail; a missing, empty or malformed floor and an unknown commit fail; the override passes loudly. `test/engram/release/floor_test.exs` pins the file and `at_least?/1`.
