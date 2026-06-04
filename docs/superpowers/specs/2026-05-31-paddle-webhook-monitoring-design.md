# Paddle Webhook Reliability Monitoring — Design

Date: 2026-05-31
Status: Draft (pending user review)
Repos touched: `engram-app/engram` (backend), `engram-app/engram-workspace` (runbook update)
Ticket: engram-app/Engram#244 (milestone `v1-launch`, p1)

## Problem

Paddle posts billing events to `POST /webhooks/paddle`. The handler verifies the signature, parses the body, then calls `Billing.upsert_from_paddle_event/1`. Today the handler has four silent-failure modes that lose money or paid-but-unupgraded customers:

1. Handler raises → Phoenix returns 5xx → Paddle retries ~72h → eventually gives up → event lost forever. No alert.
2. **Handler swallows the upserter error and returns 200** (`webhook_controller.ex:38-45`). Paddle thinks delivery worked. Customer paid, never got upgraded. No alert.
3. Signature verification edge case → 401/400 → Paddle treats as failure → eventual give-up. No alert.
4. DB write succeeds partial / wrong-tier / wrong-period → 200 returned → ghost row. No alert.

None of these surface as fast complaints. They surface weeks later as "I paid and never got Pro" emails or as chargebacks.

We want monitoring that catches all four modes, gives best forensic info, and is forward-compatible with the metrics stack we don't have yet.

## Goals

1. **Catch every money-loss drift mode**, including #2/#4 where the response code is healthy.
2. Best forensic info on every webhook event: structured log trail + exception capture.
3. Daily ground-truth reconciliation against Paddle API (the only layer that doesn't trust our own observations).
4. Forward-compat with PromEx/Prometheus when that infra is deployed (separate ticket, separate repo).
5. Single PR (`feedback_single_pr_all_changes`); runbook updates allowed as a paired workspace PR since they live in a different repo.

## Non-Goals (v1)

- Deploying Prometheus / Grafana / Alertmanager. PromEx alone wired into a void is dead pipe. Filed as follow-up infra ticket — see "Follow-up issues" below.
- Configurable alert windows (ticket explicitly drops this).
- Deadman switch for "no webhook received for >24h" (ticket drops this — operator watches dashboard manually first weeks).
- Auto-heal on drift. Reconciliation reports and exits. Replay is a manual runbook step.
- Persisting reconciliation runs to a DB table. Logs are sufficient v1; revisit if trend analysis becomes valuable.

## Architecture

Four observability layers, lowest to highest abstraction:

| Layer | Purpose | Ships v1? |
|-------|---------|-----------|
| Structured log | Forensic trail per event (entry/exit/error) | yes |
| `:telemetry` events | Forward-compat for PromEx attach later | yes |
| Sentry capture | Exception forensics (stack + breadcrumbs, deduped) | yes |
| Reconciliation | Daily ground-truth diff Paddle ↔ local DB | yes |
| PromEx + Prometheus + alert rules | Time-series trend + paging alerts | **no** — follow-up ticket on engram-infra |

### Layer 1 — Structured log per event

Modify `EngramWeb.WebhookController.paddle/2` to:

- Stamp `Logger.metadata(category: :paddle_webhook, event_type:, event_id:)` immediately after JSON decode.
- Log at `:info` on entry with the metadata only (no payload — Paddle echoes customer email/address).
- Log at `:info` on `:ok` exit with `duration_ms`.
- Log at `:error` on the swallowed `{:error, reason}` path — change current `Logger.warning` to `error` so it routes to Sentry's logger backend.
- Keep the 200 response on swallowed-error (we still want Paddle to stop retrying — reconciliation will catch the drift). The log level change makes the failure loud internally.

Existing `format_reason/1` already redacts PII; reuse.

### Layer 2 — `:telemetry` events

Wrap the upsert call in `:telemetry.span/3`:

```
:telemetry.span(
  [:engram, :paddle, :webhook],
  %{event_type: event["event_type"], event_id: event["event_id"]},
  fn ->
    case Billing.upsert_from_paddle_event(event) do
      {:ok, _} = ok   -> {ok, %{result: :ok}}
      {:error, _} = e -> {e,  %{result: :error}}
    end
  end
)
```

That emits three events automatically:

- `[:engram, :paddle, :webhook, :start]` — measurements `%{monotonic_time}`, metadata `%{event_type, event_id}`
- `[:engram, :paddle, :webhook, :stop]` — measurements `%{duration}`, metadata `%{event_type, event_id, result}`
- `[:engram, :paddle, :webhook, :exception]` — measurements `%{duration}`, metadata `%{event_type, event_id, kind, reason, stacktrace}`

Declare them in `EngramWeb.Telemetry` (already the home for `:telemetry_metrics` declarations — pinned forward, see comment at line 88) so when PromEx lands it just attaches.

### Layer 3 — Sentry

Add `:sentry` Hex dep (latest stable, currently `~> 10.0`).

`config/config.exs`:

```elixir
config :sentry,
  dsn: System.get_env("SENTRY_DSN"),
  environment_name: config_env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  context_lines: 5,
  included_environments: [:prod, :staging]
```

`config/runtime.exs` — wire `SENTRY_DSN` from env, falling back to nil (disables capture in dev/test without crashing).

`Application.start/2` — attach `Sentry.LoggerBackend` so `Logger.error` calls auto-capture. Configure `:capture_log_messages` true with `:level :error`.

**PII scrubbing.** Paddle webhook payloads contain customer email + sometimes billing address. Configure `:sentry` `:before_send` callback to scrub:

- `event.request.data` — drop entirely if present (handler doesn't pass request body to Sentry context, but defense in depth).
- Strip any string field matching `email:`, `address`, `phone`, `card`, `iban`.

Verify capture by injecting `raise "smoke test"` behind a `MIX_ENV=staging` mix task (`mix engram.sentry.smoke`) and watching the Sentry project receive it.

### Layer 4 — Daily reconciliation

New module `Engram.Billing.Reconciliation`:

```
@spec run(days_back :: pos_integer()) :: %{
  paddle_total: non_neg_integer(),
  local_total: non_neg_integer(),
  drift: [%{subscription_id: String.t(), kind: atom(), paddle: term(), local: term()}]
}
```

**Algorithm:**

1. Compute `since = DateTime.utc_now() |> DateTime.add(-days_back, :day)`.
2. Paginate Paddle `GET /subscriptions?updated_at[GTE]=<since>` (Paddle SDK or HTTP — see "Paddle client" below). Collect every subscription updated in the window.
3. For each Paddle row, look up the local `subscriptions` row by `paddle_subscription_id`.
4. Classify drift:
   - `:missing_local` — Paddle has it, we don't
   - `:status_mismatch` — `paddle.status != local.status`
   - `:tier_mismatch` — Paddle's active price ID maps to a different tier than `local.tier`
   - `:period_mismatch` — `paddle.current_billing_period.ends_at != local.current_period_end` (allow ±2 min skew)
5. Also forward-pass: every local `subscriptions` row updated in the window that the Paddle list didn't return → `:missing_remote` (treat as soft warning — could be eventual consistency).
6. Return summary + drift list.

**Reporting:**

- Each drift entry emits `Logger.error("paddle_reconciliation_drift", category: :paddle_reconcile, …)`. Sentry backend captures.
- Final summary logs at `:info` with totals.
- Exit code (Mix task): 0 always (Oban worker treats raise as failure; we don't want false-positive Oban failures from drift — drift is data, not a job failure).

**Mix task wrapper:**

```
defmodule Mix.Tasks.Engram.Billing.Reconcile do
  use Mix.Task
  @shortdoc "Reconcile local subscriptions against Paddle"
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [days: :integer])
    days = Keyword.get(opts, :days, 7)
    Mix.Task.run("app.start")
    Engram.Billing.Reconciliation.run(days) |> IO.inspect()
  end
end
```

Per `feedback_mix_task_in_release`: when invoking via `rpc` from release shell, inline the call body — do **not** `Mix.Tasks…run`.

**Oban worker:**

```
defmodule Engram.Billing.Workers.PaddleReconcile do
  use Oban.Worker, queue: :default, max_attempts: 1
  @impl true
  def perform(%Oban.Job{}) do
    Engram.Billing.Reconciliation.run(7)
    :ok
  end
end
```

Schedule in `config/config.exs` crontab block (already exists at line 45). Run daily at `"0 2 * * *"` UTC (matches `OverrideExpirySweep` cadence).

**Paddle client.** The existing `Engram.Paddle.Client` may not have a `list_subscriptions` method yet — check during implementation. If absent, add a thin function with `updated_at[GTE]` filter + cursor pagination (Paddle uses `Paginator` with `.next()`). Self-host (`PADDLE_API_KEY` unset) → reconciliation is a no-op (log `"billing_disabled, skipping"` and return).

## Schema changes

None. Reconciliation reads existing `subscriptions` table; no new columns or tables.

## Config changes

| Var | Where | Purpose |
|-----|-------|---------|
| `SENTRY_DSN` | env (staging + prod only) | Sentry project DSN |
| `SENTRY_ENV` | env (optional override) | label in Sentry |

Self-host: `SENTRY_DSN` unset → Sentry no-ops. Reconciliation no-ops when `PADDLE_API_KEY` unset. Both safe by default.

## Sequencing & PR shape

Single backend PR. Recommended commit order:

1. **Structured log + telemetry span** in `webhook_controller.ex` (no new deps). Tests: webhook controller test asserts `[:engram, :paddle, :webhook, :stop]` emitted with `:ok`/`:error` result + log lines present.
2. **Sentry dep + config + LoggerBackend + before_send scrubber.** Tests: scrubber unit tests for PII fields.
3. **Reconciliation module + tests** (mocked Paddle client; verify all four drift kinds detected).
4. **Mix task + Oban worker + crontab entry.** Tests: Oban worker test runs against mocked Paddle client.
5. **Smoke task `mix engram.sentry.smoke`** (raises on demand to verify capture pipeline end-to-end in staging).

Paired workspace PR (separate, must accompany):

- Update `docs/context/paddle-v2-launch-runbook.md`: add "Reconciliation drift response" section with manual replay procedure.
- Update `backend/docs/context/paddle-integration.md`: add "Monitoring" section linking layers.

## Acceptance (mapped to ticket #244)

Original ticket acceptance items rewritten to reflect this design — ticket should be updated:

- [ ] Structured logs on webhook entry/exit/error with redacted metadata
- [ ] `:telemetry` events `[:engram, :paddle, :webhook, :*]` emitted (PromEx-ready)
- [ ] Sentry capture wired with PII `before_send` scrubber; staging smoke task verifies pipeline
- [ ] `Engram.Billing.Reconciliation.run/1` detects all four drift kinds
- [ ] `mix engram.billing.reconcile [--days N]` runs locally + in release
- [ ] `Engram.Billing.Workers.PaddleReconcile` scheduled daily 02:00 UTC
- [ ] `paddle-v2-launch-runbook.md` updated with drift response + manual replay
- [ ] `backend/docs/context/paddle-integration.md` updated with monitoring section
- [ ] Manual smoke (staging): take backend offline 5 min during webhook delivery, verify Paddle retries + reconciliation catches drift if any persists

Dropped from original acceptance (ticket-level update required):

- ~~"Alert rules deployed (5xx rate, exception rate)"~~ — moves to follow-up Prometheus ticket.

## Follow-up issues to file

1. **engram-app/engram-infra** — "Deploy Prometheus/Grafana stack + wire PromEx + alert rules for Paddle webhook". Requires Prometheus scrape target (we have none today). Carries the dropped acceptance item.
2. **engram-app/Engram** — "Reconciliation: persist runs to `reconciliation_runs` table for trend analysis". Defer until we have a need (after first month of operating).

## Open questions

1. Sentry DSN — staging + prod use the same project with `environment_name` distinguishing, or two projects? Default: one project, environment label.
2. Reconciliation window default: 7 days. Reasonable? Paddle retries for ~72h so a 7-day window catches any retry that eventually succeeds + a buffer.
3. `:missing_remote` (local has, Paddle window doesn't return) — log as warn or info? Default: warn but no Sentry capture (could be benign eventual consistency).

## Risks

- Sentry adoption is a new external service to monitor + a new ENV secret in two envs. Mitigated: defaults disabled when DSN unset; smoke task verifies end-to-end before relying on it.
- `:before_send` PII scrubber bug could leak customer email/address to Sentry. Mitigated: unit tests for scrubber; manual inspection of first 5 captures in staging.
- Reconciliation that hits Paddle API frequently could rate-limit. Mitigated: daily cadence + paginated. Paddle rate limit is generous (300 req/min).
- Changing the swallowed-error log from `warning` to `error` will start triggering Sentry on every existing transient upsert failure. May surface noise on day one — accept this; tune via Sentry's grouping/ignore rules if any one fires hot.
