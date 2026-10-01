# Schema-impact banner stamped IRREVERSIBLE with no migrations

_Last verified: 2026-09-30 (fixed in #1810)_

## Trigger

A release PR's schema-impact notes say **IRREVERSIBLE** but the release has no
migrations, or you are touching `scripts/generate_schema_impact_notes.sh`.

## Symptom

Release 0.37.0 (#1807) carried a `phase/*` PR and zero migrations, and the
banner still claimed a rollback-irreversible migration.

## Root cause

Detection was `git diff --name-only ... | xargs -r grep -l marker` used as an
`if` condition. On empty input `xargs -r` skips running `grep` entirely and
exits 0. `if` read that 0 as "marker found".

The live detection path had no test: every test case set
`IRREVERSIBLE_OVERRIDE`, so the git + grep branch never ran under test.

## Fix (#1810)

- Grep only when the diff returned files (`[ -n "$changed" ] && ...`).
- `--diff-filter=AM` so deleted/renamed-away migrations are not grepped.
- Fail loud if `git diff` itself errors instead of treating it as "no files".
- 5 tests in `test/scripts/generate_schema_impact_notes_test.sh` that build a
  real scratch git repo and exercise the live path with no override.

## Rule

- `cmd | xargs -r grep -q ...` is not a boolean: on empty input it is always
  true. Check for input first.
- A test override hook can hide the real code path. Keep at least one test per
  branch that runs without the override.

## Evidence

- #1807 (0.37.0 release PR with the false banner)
- #1810 (fix + tests)
