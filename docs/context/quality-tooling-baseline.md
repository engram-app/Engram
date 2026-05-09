# Quality Tooling Baseline

_Captured 2026-05-09 on `chore/quality-tooling-foundation` (PR #TBD). Each subsequent phase fixes findings + updates this doc with the new ratchet ceiling._

Plan: `../../../engram-workspace/docs/superpowers/plans/2026-05-09-quality-tooling-rollout.md`

## Snapshot

| Tool | Findings | Status | Ratchet target |
|------|----------|--------|----------------|
| `mix format` | 0 | **gated** (Phase 2) | 0 (held) |
| `mix compile --warnings-as-errors` | 0 | **gated** (Phase 2) | 0 (held) |
| Sobelow (threshold low, exit low, --skip) | 0 | **gated** (Phase 3) | 0 (held) |
| Dialyzer (with `:unmatched_returns`, `:error_handling`, `:underspecs`, `:missing_return`, `:extra_return`) | 81 | informational (Phase 4 → fatal) | 0 |
| Credo (`--strict`) | 676 | informational (Phase 5 → fatal) | 0 |

## Format

`mix format --check-formatted` → exit 0 after the T3.7-leftover autofix (commit `ee78df6`). Gateable from Phase 2.

## Compile warnings-as-errors

`mix compile --warnings-as-errors --force` → exit 0, 0 warnings. Already enforced in `mix precommit` alias but never wired into CI; Phase 2 closes that gap.

## Sobelow

`mix sobelow --exit low --skip` → exit 0. No XSS, SQL-injection, path-traversal, RCE, command-injection, DoS, or known-vuln-dep findings at the strictest threshold. Already gateable; Phase 3 promotes.

## Dialyzer

`mix dialyzer --quiet` → 81 findings (PLT 7.5 MB, first build ~6 min on dev box). Breakdown:

| Category | Count | Notes |
|----------|-------|-------|
| `:unknown_type` | 32 | Ecto schema `t/0` types referenced before they're declared on the schema modules. Add `@type t :: %__MODULE__{...}` to each schema. |
| `:unmatched_return` | 28 | Raw `Ecto.Adapters.SQL.query/4` results not bound. Bind to `_` or pattern-match the `%{:rows => _}` map. |
| `:pattern_match_cov` | 6 | A clause is covered by an earlier one — dead code. |
| `:contract_supertype` | 4 | `@spec` claims a wider type than the function actually returns. Tighten the spec. |
| `:pattern_match` | 3 | Pattern can never match (real bug indicator). |
| `:missing_range` | 3 | `@spec` covers fewer return types than the body produces. |
| `:guard_fail` | 2 | Guard always evaluates false. |
| `:unused_fun` | 1 | Dead function. Delete or pin. |
| `:no_return` | 1 | `Engram.Billing.create_checkout_session/2` — likely a Stripe contract mismatch, see `:call` below. |
| `:call` | 1 | `Stripe.Checkout.Session.create/1` call shape mismatch — same site as the `:no_return` above. Probably the actual bug. |

Phase 4 burns this list to zero. The `:no_return` + `:call` pair on `Engram.Billing` is the highest-value finding — that's the kind of latent bug the rest of this rollout exists to surface. The 32 `:unknown_type` fixes are mechanical (one `@type t` per schema). Anything that genuinely is OK lands in `.dialyzer_ignore.exs` with a justification comment.

## Credo (strict)

`mix credo --strict --mute-exit-status` → 676 findings across 230 files. Breakdown:

| Category | Count | Notes |
|----------|-------|-------|
| `[C]` Consistency | 384 | Mostly `Consistency.UnusedVariableNames` — `_email` instead of `_`. Mechanical fix. |
| `[D]` Software design | 105 | Mostly `Design.AliasUsage` — nested modules called inline that should be aliased. |
| `[F]` Refactor | 90 | `Refactor.Nesting` (45), `Refactor.CyclomaticComplexity` (17), `Refactor.UtcNowTruncate` (13). |
| `[W]` Warning | 52 | Mix of `LeakyEnvironment`, `MapGetUnsafePass`, `MixEnv`, `UnsafeToAtom` — security-relevant. |
| `[R]` Readability | 45 | `AliasOrder` (14), `MaxLineLength` overflow, `ModuleDoc` (3). |

Phase 5 burns this down to zero. Most categories are mechanical; the security `[W]` group needs careful triage (a real `UnsafeToAtom` is a DoS bug).

## How to reproduce these counts

```bash
cd backend
mix format --check-formatted          # exit-status only
mix compile --warnings-as-errors --force
mix credo --strict --mute-exit-status # full report
mix sobelow --exit low --skip         # full report
mix dialyzer                          # full report (PLT must be built first via mix dialyzer --plt)
```

## Update protocol

When a phase lands:

1. Re-run the relevant command and update the count in the snapshot table above.
2. Mark the row as **gated** once `continue-on-error: true` is dropped from the corresponding CI step.
3. Commit the update in the same PR that promotes the gate.
