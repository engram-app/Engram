# Customer insights: our own event log, daily snapshots, operator page

_Last verified: 2026-10-20. Spec: Engram vault `50 Engineering/_Superpowers Specs/2026-10-19-customer-insights-design.md`._

Read this before touching `Engram.Analytics.EventLog`, `Engram.Insights`,
`Engram.Insights.Snapshot`, the operator role, or `/api/operator/insights`.
Event names and props are in `product-activity-analytics.md`.

## Three parts

1. **`analytics_events`**: every `Engram.Analytics` event (`track`,
   `track_throttled`, `track_folded`, `track_anonymous`) is also written
   here by `EventLog.record/3`: after the caller's transaction commits
   (`Repo.after_commit`) into an ETS buffer (`EventLog.Buffer`) written in
   one statement every 5s, at 500 rows, and on shutdown (a hard crash loses
   one interval). Same opt-out (a nil distinct id records nothing anywhere)
   and the same throttling as PostHog, and recorded whether or not PostHog
   is configured. Anonymous events have `user_id` NULL; `account_deleted`
   and `account_delete_reason` are stored at day precision, and
   `account_deleted`'s plan as free/paid. Props pass an ALLOWLIST of bounded
   keys (`EventLog.allowed_keys/0`), strings cut at 64 chars: free text, a
   feedback reply address and any new unlisted prop are dropped until
   someone lists them. Opting out deletes the user's rows here and in both
   snapshot tables. The web app's own funnel events (paywall, checkout,
   onboarding steps, connects) arrive through `POST /api/analytics/events`
   (browser session only, schema mirrored from `events.ts` in
   `Analytics.ClientEvents`, recorded here only, never forwarded to
   PostHog). Throttled counts no later event picks up are sent as
   `<event>_rollup` every 5 minutes (`Analytics.Folds`).
   `AnalyticsEventsPrune` (hourly, :58) deletes rows older than 730 days.
   Config `:analytics_event_log` (default true; false in `config/test.exs`,
   a test turns it on and flushes with `EventLog.flush/0`).
2. **Daily snapshots**: `Engram.Workers.DailySnapshot` (00:40 UTC) calls
   `Engram.Insights.Snapshot.run/1`, which writes the day before the job
   was inserted to
   `user_daily_metrics` (the `PersonProperties.by_user/0` facts plus api keys
   created, embed budget %, and the day's searches / MCP tool calls / web
   edit from the event log) and `vault_daily_metrics` (notes, bytes,
   attachments, distinct folders, links, distinct tags; vault id only).
   Upserts keyed on (id, date), so reruns are idempotent. Vaults go in
   chunks of 500 ids, each its own query and commit; a retry skips vaults
   its job already wrote, so a timeout does not lose the day. Each run also
   rebuilds the 7 days before yesterday's activity rollups; a day the job
   missed gets activity but `captured_at` NULL and empty state columns,
   since account state cannot be recovered after the fact.
3. **Operator page**: `/operator` in the SPA, `GET /api/operator/insights`
   (report list), `/:report`, `/users/:user_id` (timeline).

## Not tenant tables

The four new tables (`analytics_events`, `user_daily_metrics`,
`vault_daily_metrics`, `role_change_log`) have no RLS, like `usage_meters`:
counts and bounded props only, read only by the snapshot job and
`Engram.Insights`. Every row about a user cascades with the account
(`role_change_log.actor_id` nilifies). So they need no `maintenance_all`.
The snapshot and reports still read the TENANT tables (vaults, notes,
subscriptions, onboarding_actions) through `Repo.maintenance()`; proven by
`daily_snapshot_maintenance_test.exs` and `insights_maintenance_test.exs`
(app pool dropped to `engram_app`, no tenant).

`Engram.Insights` is the one web-request use of the maintenance pool
(besides the Paddle webhook): `Repo.Maintenance`'s "Oban workers only"
rule is waived for it on purpose, behind `RequireOperator`, read-only.

## Operator role

- `users.role = "operator"`. Granted ONLY from the release console:

  ```
  /app/bin/engram eval 'Engram.Release.grant_operator("you@example.com")'
  /app/bin/engram eval 'Engram.Release.revoke_operator("you@example.com")'
  ```

  member <-> operator only (an admin is never changed). Each logged in
  `role_change_log` (`actor_id` NULL = console, `scope` "platform").
- No changeset casts `:role` (`operator_role_test.exs` lints `lib/`);
  `Accounts.set_role/2` accepts admin/member only.
- `RequireOperator`: active operator on a browser session; everything else,
  including an operator's API key, plugin token or OAuth grant, gets 404.
  Own scope, GET routes only. The SPA renders the ordinary 404 page unless
  `/api/me` says `role: "operator"`.
- Team admin later is a separate route and an org-membership role; never a
  role switch on this route, never this column.

## Reports (`Engram.Insights.report(name, :all, days: n)`)

`funnel`, `converters`, `path_to_paid`, `limits`, `surfaces`, `ai_apps`,
`vaults`, `retention`, `billing`, `churn_signals`, plus `timeline/2`.
Only `:all` exists; `{:org, id}` is the planned team scope. Operators and
opted-out users are excluded everywhere. Rows name users by id only.
`?days=` bounds a report (default 180, max 730): signups in the window for
funnel, converters, path_to_paid and retention; events in the window for
the rest.

Definitions that are easy to get wrong:

- **Paid** = a `payment_completed` with a non-zero `amount_bucket`, or a
  non-discounted `subscription_started`. A 100%-off comp never counts.
- **MRR** counts only entitled subscriptions whose user has a real payment
  in the event log, at list price (Starter $7, Pro $14). Comped accounts,
  trials and subscriptions older than the event log show as
  `unverified_subscriptions`. Expect MRR to under-read until the first
  renewal of every real subscription lands in the log.
- **Funnel sources**: signup, first vault (`vaults.created_at`), Obsidian
  linked and AI connected (`onboarding_actions`, else the events) are durable.
  Everything else exists only from the day the event log shipped.
- **`paywall_shown` / `checkout_opened`** are web-app events; they reach
  `analytics_events` through `POST /api/analytics/events`, from the release
  that shipped it onward.
- **Converters peers** are users who had not paid by the payer's tenure,
  including users who paid later.
- **Cancel reasons** come from `subscription_cancel_reason` (the cancel
  survey); a cancel without the survey has no reason.
- Aggregation is in SQL: a report returns a row per user (or user-week) at
  most, never per event. `converters` builds payer x user pairs in
  Postgres (`ponytail:` note): precompute per-user daily states if that
  outgrows a request.
