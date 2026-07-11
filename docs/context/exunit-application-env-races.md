# ExUnit Application.put_env race — async-mutator anti-pattern

_Last verified: 2026-05-21_

Tests that mutate `Application.put_env/3` (or `Application.delete_env/2`) while declared `async: true` are a flake source. `Application` env is a single global ETS table — the Ecto SQL sandbox isolates DB rows per test, but does **nothing** for application env. Concurrent readers in other async modules can observe the temporary value mid-test.

## Symptom shape

A reader test in module A passes in isolation, passes for its own module, passes for the full suite most of the time, then occasionally fails in CI. Failure surface is always "production code branched the wrong way" — e.g. `enforced?()` returned `false` so the limit guard was skipped, or a feature flag flipped, or an HTTP client hit the wrong base URL.

Rerunning passes. Looks like a sandbox / RLS / timing bug. It is not.

## Concrete instance (closed)

[engram-app/engram#183](https://github.com/engram-app/engram/issues/183) — `EngramWeb.VaultsControllerTest` "returns 402 when vault limit reached" returned 201 ~30% of seeds when run alongside `Engram.Billing.LimitsTest`.

- Mutator: `test/engram/billing/limits_test.exs` was `async: true` with a `describe "bypass (self-host) — :limits_enforced=false"` block that called `Application.put_env(:engram, :limits_enforced, false)` in `setup`, restored in `on_exit`.
- Reader: `Billing.effective_limit/2` consults `Application.get_env(:engram, :limits_enforced, true)` before the 4-layer resolver. During the bypass window, it returns `:unlimited` → `check_limit/3` returns `:ok` → vault insertion proceeds.
- Visible result: `register_vault` returned `{:ok, vault, :created}` instead of `{:error, :vault_limit_reached}` → controller responded 201 not 402.

Local repro (PR #188 verification):
```
mix test test/engram/billing/limits_test.exs \
  test/engram_web/controllers/vaults_controller_test.exs --seed 5
```
yielded a failure on `:159` (`POST /api/vaults/register returns 402`) and `:77` (`POST /api/vaults returns 402`) in roughly 1 of 3 runs across seeds 1-20.

## Fix

The mutator side is the bug. Mark the mutating module `async: false`:

```elixir
defmodule Engram.Billing.LimitsTest do
  # async: false — bypass + default describe blocks mutate
  # Application.put_env(:engram, :limits_enforced, ...), which is global to
  # the BEAM. Under async, concurrent readers in other modules observe the
  # bypass mid-test. See engram-app/engram#183.
  use Engram.DataCase, async: false
  ...
end
```

ExUnit schedules `async: true` cases first, then `async: false` cases serially — so the mutator runs alone, no concurrent reader exists.

**Do not** apply `async: false` to the readers. That hides this race in one consumer at a time while leaving the same trap for the next consumer of the same config key.

## Audit (as of PR #188)

Other async modules that mutate Application env, **not yet known to flake** (no observed CI failure):

- `test/engram/embedders/voyage_test.exs` — `:voyage_url`, `:voyage_api_key`
- `test/engram_web/endpoint_config_test.exs` — `:websocket_check_origin`

Both are preemptive risks. They survive only because no other async test currently calls into the code that reads those keys during the same window. The moment such a reader is added, they will flake the same way.

## Rule of thumb when reviewing test code

If a test calls `Application.put_env`, check that:

1. The module is `async: false`, **or**
2. The key being mutated is read by nothing else during tests (e.g. config that only affects this module's behavior).

(2) is fragile — a new code path elsewhere that reads the key turns the test into a flake source. Default to (1).

## Alternative architectures (out of scope for the immediate fix)

If a config flag is read enough that serializing its mutator slows CI noticeably, push the override into a process-scoped mechanism:

- `Process.put/2` inside the call site (only the test process sees the override).
- A `Mox`-style explicit-set helper that stores per-process state.
- A `ProcessTree.get/2`-style fallback chain.

None of these were warranted for `:limits_enforced` (one short test module, milliseconds saved). Documented here so the next reviewer doesn't reach for `async: false` reflexively when the right answer is "stop reading from global env."
