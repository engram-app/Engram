# Context Doc: the e2e vault is SESSION-scoped — a vault-wide assertion can never go green

_Last verified: 2026-08-24_

## Status
Root-caused and fixed. Engram#1459 (`5e9f0617`) scoped `read_lineages` to a path
prefix. `main` was red on `e2e-clerk` for ~13h before that landed.

## What this is

`e2e/tests/test_97_first_sync_single_lineage.py`,
`test_98_resync_to_fresh_vault_single_lineage.py` and
`test_100_frontmatter_echo_single_lineage.py` asserted "no note in the vault
holds more than one Yjs client lineage" — the fence for the 2026-08-23 first-sync
content-doubling bug (`docs/context/crdt-frontmatter-reseed-second-lineage.md`).

They failed on **every** CI run from the moment they merged in #1455. They were
merged red and never once passed. No product fix could have made them pass.

## Root cause

`e2e/helpers/lineage_probe.py`'s `read_lineages` sampled

```sql
select id from notes where vault_id=$1 and deleted_at is null
```

— the whole vault, no path filter. Three facts make that fatal:

1. **The vault fixtures are `scope="session"`.** `sync_vault_id` and `vault_a`
   (`e2e/conftest.py`) are both session-scoped: ONE vault serves the whole
   ~110-test suite and its notes persist between tests. Already documented
   in passing by `test_77`'s `_cleanup_bulk_residue`: *"Fixtures are
   session-scoped (conftest) and only Clerk USERS are swept between runs — vault
   notes persist."*
2. **Each test owns ~11-15 prefixed notes** (`Lineage-{run}/`, `Resync-{run}/`,
   `Roundtrip-{run}/`) but was asserting across 78-146 vault-wide notes.
3. **34 of 65 e2e test files drive a second Obsidian device** (`grep -l vault_b
   e2e/tests/*.py`). A note legitimately edited by two devices holds TWO Yjs
   clients. That is correct CRDT behaviour, not corruption.

So the assertion had a permanent non-zero floor made of other tests' correct
notes. Nothing shipped in the product could ever reach it.

## The tell: the number did not move

The counts were suspiciously immovable — 12/135 then 12/146 in back-to-back runs
against two DIFFERENT plugin builds, and `test_98` contributed 11 fresh notes of
its own while adding **0** new multi-client ones.

**A real product bug responds to product changes.** An immovable count is
measuring something the product does not control.

## The diagnostic that settled it: make the probe NAME the rows

Instrumenting the probe to print the PATH of every multi-client note, not just
the count:

```
5  E2E/RapidEdits-…              7  E2E/RapidEditsStale-…   (the "worst: 7 clients")
2  E2E/Referrer88b-…             2  E2E/Outside88-…
2  E2E/ApiUpdateRT.md            2  E2E/ModifyTest.md
3  E2E/AppendSync37.md           3  E2E/CreateRace-…/Raced.md
3  E2E/Orchestra-…               3  E2E/MissedDelivery-…/Note.md
2  E2E/HashOnlyLive.md
```

Every flagged note belonged to a different test. ZERO under `Roundtrip-*`,
`Lineage-*` or `Resync-*` — the three tests' own fixtures were 100% clean the
entire time.

**Near-miss worth knowing:** `test_100` reported "7 doubled" while ALSO rewriting
exactly 7 of its own round-trip-hostile YAML files on disk. That 7 == 7
coincidence strongly suggested its own fixture was the culprit and nearly sent
the investigation down the wrong path. Only the per-path output disproved it.

**A count alone cannot attribute a failure.** Any probe backing an assertion
should be able to name the offending rows.

## The fix (#1459)

- `read_lineages(vault_id, path_prefix="")` filters to the caller's own prefix;
  all four call sites pass the prefix the test already computed.
- **Filtering happens in Elixir AFTER decrypting each note, not in SQL.** `path`
  is encrypted at rest — there is no plaintext column to `LIKE` against.
- Added `assert lineages.notes >= NOTE_COUNT` vacuity guards: a broken filter
  would otherwise report `0/0` and pass.
- The per-path printing is kept permanently (`LINEAGE_MULTI\t<n>\t<path>`).

Result: `110 passed, 1 skipped`, all three green, `main` unblocked.

## Failed approaches / dead ends

**The first hypothesis was a real bug that was not this bug.** Overlapping
`fullSync()` sweeps race `pushFile`'s reentrancy guard — `this.pushing.has(path)`
is checked at entry but only claimed after two awaits — which can mint two
genesis lineages. That TOCTOU is REAL, was fixed separately in plugin PR
engram-app/Engram-obsidian#467, and did take `e2e-crdt` from 4 failures to green.

It did **not** change the lineage counts at all: 7/78, 12/135, 12/146 before and
after. Two real bugs, only one of which was the one being chased.

**When a fix does not move the number, believe the number.**

## Gotchas for anyone adding an e2e assertion

- Assume the vault is dirty. Any global "count X across the vault" assertion is
  measuring ~110 other tests unless you scope it to your own fixture prefix.
- `>= 0`-shaped assertions pass vacuously when a filter is wrong. Pair every
  filtered count with a floor on the denominator.
- `path` is encrypted; vault-wide SQL cannot filter on it. Filter after decrypt.
- Never merge a new e2e test that has not been green in CI at least once. All
  three of these went in red and stayed red for 13 hours.

## References

- `e2e/helpers/lineage_probe.py` (module docstring carries the short version)
- `e2e/conftest.py` — `sync_vault_id` / `vault_a`, both `scope="session"`
- `e2e/tests/test_97_first_sync_single_lineage.py`, `test_98_…`, `test_100_…`
- `docs/context/crdt-frontmatter-reseed-second-lineage.md` — the defect these
  tests fence
- Engram#1455 (tests merged red), Engram#1459 (`5e9f0617`, the scoping fix),
  engram-app/Engram-obsidian#467 (the unrelated real `pushFile` TOCTOU)
