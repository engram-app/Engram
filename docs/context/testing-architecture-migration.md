# Testing-architecture migration: report-only e2e + the flake ledger

**Trigger:** you hit a comment in `verify.yml` pointing here, or you're asking
"why doesn't a red e2e suite block my PR?" or "how do we know when to trust a
flaky suite again?"

## What changed

The full-Obsidian e2e suites — `e2e-clerk`, `e2e-crdt`, `e2e-browser` — moved
from **hard gate** to **report-only** in the `ci` aggregate job. They still run
on every push and post their own PR checks, but a failure emits `::warning::`
instead of failing the merge (see `verify.yml`, the `ci` job's "REPORT-ONLY"
block). They remain the gate on **main / nightly / `release-v*`**.

## Why

Real Obsidian + Xvfb + CDP + Playwright on shared self-hosted runners is
structurally nondeterministic — the suite flaked ~50% for reasons unrelated to
the code under test (runner contention, boot timing, Clerk rate limits). A gate
that's a coin-flip stops nothing real while blocking correct, unit-proven work.
So convergence is now gated **deterministically** elsewhere, and the flaky
integration suite became a signal, not a blocker.

## What gates convergence now (deterministic, hard-required)

- **`unit-tests`** — includes the CRDT head-consistency property test.
- **plugin sim tier** — the differential gate in the plugin repo (`Engram-obsidian`).
- **`headless-protocol`** — real plugin SyncEngine vs real backend over real
  WebSockets with event barriers (no Obsidian, no wall-clock waits). Currently
  report-only itself; promotion criterion is in its job header in `verify.yml`.

## The safety net: nightly flake ledger + auto-alert

Report-only can't mean "ignored forever". The `ledger-append` job (nightly,
06:00 UTC) records each suite's pass/fail to the **`ci-ledger` orphan branch**
(`flake-ledger.jsonl`, schema `{date, sha, workflow_run_id, suite, result,
duration_s}`) and renders a **trailing-14-night flake rate** per suite.

- Rate math lives in `scripts/flake_ledger_rates.jq` (dedup on
  `(workflow_run_id, suite)` + 14-night window), tested offline by
  `scripts/flake_ledger_rates_test.sh`.
- **Auto-alert:** a suite red on **>=40%** of the trailing 14 nights (once
  there are **>=5** nights of data) auto-opens a `flaky-suite` GitHub issue;
  it auto-closes when the rate recovers. This is the only human touchpoint —
  you don't watch the branch, the branch pokes you.

## Promoting a suite back to gating

Manual and deliberate — do NOT automate it (auto-promotion re-introduces a
flaky gate). Flip a report-only suite to required only after ~10 consecutive
**infra-clean** green runs, using the ledger's measured rate as evidence and
excluding infra-only reds (docker `--wait` / `docker pull` / `bun install
--frozen-lockfile`). Add it to `ci`'s `needs:` + the pass/fail loop.
