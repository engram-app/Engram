# Quality Tooling Baseline

_Captured 2026-05-09 on `chore/quality-tooling-foundation` (PR #TBD). Each subsequent phase fixes findings + updates this doc with the new ratchet ceiling._

Plan: `../../../engram-workspace/docs/superpowers/plans/2026-05-09-quality-tooling-rollout.md`

## Snapshot

| Tool | Findings | Status | Ratchet target |
|------|----------|--------|----------------|
| `mix format` | 0 | **gated** (Phase 2) | 0 (held) |
| `mix compile --warnings-as-errors` | 0 | **gated** (Phase 2) | 0 (held) |
| Sobelow (threshold low, exit low, --skip) | 0 | **gated** (Phase 3) | 0 (held) |
| Dialyzer (with `:unmatched_returns`, `:error_handling`, `:underspecs`, `:missing_return`, `:extra_return`) | 0 (4 ignored) | **gated** (Phase 4) | 0 (held) |
| Credo (`--strict`) | 676 | informational (Phase 5 → fatal) | 0 |

## Format

`mix format --check-formatted` → exit 0 after the T3.7-leftover autofix (commit `ee78df6`). Gateable from Phase 2.

## Compile warnings-as-errors

`mix compile --warnings-as-errors --force` → exit 0, 0 warnings. Already enforced in `mix precommit` alias but never wired into CI; Phase 2 closes that gap.

## Sobelow

`mix sobelow --exit low --skip` → exit 0. No XSS, SQL-injection, path-traversal, RCE, command-injection, DoS, or known-vuln-dep findings at the strictest threshold. Already gateable; Phase 3 promotes.

## Dialyzer

Phase 4 (this PR) burned the 81-finding baseline to **0 effective findings, 4 skipped** in `.dialyzer_ignore.exs`:

- 3× `Engram.Crypto.aad_for_row/3`, `aad_for_qdrant/3`, `aad_for_wrapped_dek/1` — `:contract_supertype`. Specs are intentionally `binary()` so callers don't depend on the exact byte layout. Dialyzer's success typing (with `:underspecs` flag) infers tighter `<<_::N, _::_*8>>` shapes from the literal-string concatenation, but narrowing the spec would leak implementation details.
- 1× `Engram.Notes.Helpers.extract_title/2` — `:missing_range`. Dialyzer reports a phantom `{integer(), integer()}` return shape that no real call path produces (every internal helper is guarded with `is_binary/1`). Likely a `Path.rootname/1` / `Regex.run/3` success-typing quirk.

Real bugs found and fixed:

- **`Engram.Billing.create_checkout_session/2` `:no_return` + `:call`** — passed `mode: "subscription"` (string) and `payment_method_collection: "always"` (string) to Stripe's Checkout Session SDK, whose v3 type contract requires atoms (`:subscription`, `:always`). The Stripe wire form converts atoms to strings internally, so this likely worked at runtime but matched the SDK contract incorrectly — and any future Stripe SDK bump that tightened the validation would have broken it.
- **`Engram.Auth.TokenResolver.resolve/1` `@spec` underspec → `EngramWeb.Plugs.Auth.format_reason/1` `:guard_fail`** — spec said `{:error, atom()}` but Joken returns claim-validation failures as keyword lists. Widened to `atom() | keyword()`. The downstream `format_reason/1` clauses are now correctly typed.
- **`Engram.Notes.upsert_note/3` `@spec` missing `:version_conflict` shape** — caused `:pattern_match` warnings in `EngramWeb.NotesController.upsert/2` for the version-conflict branch. Spec widened to include `{:error, :version_conflict, Note.t()}`.

Mechanical cleanups:

- 32× `:unknown_type` — added `@type t :: %__MODULE__{}` to `Accounts.User`, `Accounts.ApiKey`, `Notes.Note`, `Vaults.Vault`, `Attachments.Attachment`.
- 28× `:unmatched_return` — bound `Ecto.Adapters.SQL.query!/4`, `Repo.update_all/2`, `Repo.delete_all/2`, `Phoenix.Endpoint.broadcast/3`, etc. results to `_` at fire-and-forget call sites; added `@spec ... :: :ok` to `broadcast_change/4-5` so call sites can pattern-match.
- 6× `:pattern_match_cov` — removed dead clauses now reachable as Dialyzer's success typing improved (e.g. `Crypto.decrypt_phase_b_*`'s impossible `{:error, _}` arm; `health_controller`'s atom fallback after spec narrow).
- 1× `:unused_fun` — `EngramWeb.NotesController.classify_reason/1`'s changeset/exception/unknown clauses were dead after the upsert spec widen; collapsed to the single `is_atom` arm.

Test surgery: `EngramWeb.NoInspectInJsonResponseTest` was failing on `main` after the Phase 1 `mix format` autofix moved `# noqa: T3.0.6` markers onto the line *above* their `inspect(...)` calls (long lines got broken). Updated `scan_file/1` to accept the marker on the immediately preceding line as well.

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
