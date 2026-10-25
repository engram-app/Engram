# Paddle integration

_Last verified: 2026-10-24_

How Engram talks to Paddle Billing. Owner: billing / monetization. Status: shipped end-to-end (PR #132; Stripe removed entirely). Billing is live, `RequireOnboarding` gates the vault pipeline, and the Paddle.js overlay is wired.

## Why Paddle

- **Merchant of Record.** Paddle collects + remits VAT, GST, and US sales tax on our behalf. No tax-engine, no per-jurisdiction registration, no compliance audits. For a global SaaS this is the single biggest reason to choose Paddle over Stripe.
- **Affiliate-friendly.** Paddle has native integrations with Rewardful, FirstPromoter, Tapfiliate, and Impact. Referral IDs can ride along on the checkout via `custom_data`, which we persist on `subscriptions.custom_data`. The app does not send any affiliate keys yet.
- **Frontend-first overlay.** Paddle.js exposes `Paddle.Checkout.open()` which opens an inline overlay (no page redirect). The backend never creates a checkout session — it only configures the frontend and reacts to webhooks.

## Architecture

```
Browser (marketing site OR app)
  └─ loads paddle.js with PADDLE_CLIENT_TOKEN
  └─ GET /api/billing/config            → client_token + price_ids + customer_email + custom_data
  └─ user clicks "Subscribe"
  └─ Paddle.Checkout.open({ items, customer, customData, settings })
       └─ overlay handles payment + trial card capture
       └─ on success: Paddle redirects to successUrl AND fires webhooks

Paddle webhooks → POST /webhooks/paddle
  └─ verify Paddle-Signature (HMAC-SHA256 of ts:body, semicolon-delimited)
  └─ Engram.Billing.upsert_from_paddle_event/1
       └─ subscription.created          → insert subscriptions row (status, tier, custom_data)
       └─ subscription.activated/updated → update row (status, tier, current_period_end)
       └─ subscription.past_due          → set status "past_due"
       └─ subscription.canceled          → set status "canceled"
       └─ transaction.payment_failed     → report a stalled checkout (#1737)
       └─ transaction.updated            → report a stalled checkout (#1737)
       └─ transaction.completed          → log paddle_transaction_completed
       └─ anything else                  → {:ok, :ignored} + a debug line
```

## Module map

| Module | Purpose |
|--------|---------|
| `Engram.Paddle.Client` (`lib/engram/paddle/client.ex`) | Behaviour for every Paddle API call (portal sessions, subscriptions, transactions, invoices, cancel, plan-change preview/update, `list_subscriptions/1`). `impl/0` reads `:paddle_client` config so tests can swap in Mox. |
| `Engram.Paddle.Client.HTTP` (`lib/engram/paddle/client/http.ex`) | Default Req-based impl. Base URL switches on `:paddle_env` (`production` → api.paddle.com, else sandbox-api.paddle.com). |
| `Engram.Billing` (`lib/engram/billing.ex`) | `upsert_from_paddle_event/1`, `create_portal_session/1`, `tier/1`, `active?/1`, `trial_days_remaining/1`. |
| `EngramWeb.WebhookController.paddle/2` | Signature verify + dispatch to `upsert_from_paddle_event/1`. |
| `EngramWeb.BillingController` | `:status`, `:config` (overlay payload), `:customer_portal`, `:subscription_detail`, `:transactions`, `:transaction_invoice`, `:cancel_subscription`, `:reverse_cancel`, `:plan_change_preview`, `:plan_change_confirm`, `:payment_update_transaction` (see the billing scope in `router.ex`). |

## Webhook signature

Paddle signs each notification:

```
Paddle-Signature: ts=<unix_seconds>;h1=<hex_hmac_sha256>
```

The signed payload is `"<ts>:<body>"` (colon, not period — different from Stripe). The MAC is HMAC-SHA256 keyed with `PADDLE_NOTIFICATION_SECRET`. We reject any signature older than 300 seconds to prevent replay. Verification reuses `EngramWeb.Plugs.CacheRawBody` (registered in `endpoint.ex`) which preserves the raw body for HMAC re-computation.

## `custom_data` contract

When the frontend opens `Paddle.Checkout.open()`, it MUST include at least `user_id` in `customData`. Optional keys carry affiliate / attribution data:

```js
Paddle.Checkout.open({
  items: [{ priceId: cfg.price_ids.starter.monthly, quantity: 1 }],
  customer: { email: cfg.customer_email },
  customData: cfg.custom_data,   // { user_id: ... }; extra attribution keys would go here
});
```

The live call is in `frontend/src/billing/billing-page.tsx`.

Whatever the overlay sends becomes `data.custom_data` on every subscription webhook for that subscription. The backend persists the full map on `subscriptions.custom_data` (JSONB), keyed off the initial `subscription.created` event. Subsequent updates leave `custom_data` untouched so the original attribution survives plan changes.

`user_id` resolution accepts either integer or stringified integer — Paddle returns JS-typed values that arrive over the wire as strings in some configurations.

## Event lifecycle

| Event type | What we do | Why |
|------------|------------|-----|
| `subscription.created` | Insert row (or upsert on `user_id` conflict). Populates `paddle_customer_id`, `paddle_subscription_id`, `tier`, `status`, `current_period_end`, `custom_data`, `last_event_occurred_at`. | First touch: bind the Paddle entities to the user. With no trial on any price, this normally arrives with status `active`. |
| `subscription.activated` | Update `status`, `tier`, `current_period_end`, `last_event_occurred_at` by `paddle_subscription_id`. If no row holds that id yet, it takes the `subscription.created` insert path (see "Retries and ordering"). | Fires when a subscription with no trial becomes active (and, historically, when a trial converted). |
| `subscription.updated` | Same as activated. | Plan change, billing cycle roll, dunning recovery. |
| `subscription.past_due` | Same as activated; status becomes `"past_due"`. | Card declined, retry in progress. `past_due` is in `@entitled_statuses`, so `tier/1` still reports the paid tier during the grace window. |
| `subscription.canceled` | Status becomes `"canceled"`. Same first-event insert path as activated. | End of life. `canceled` is NOT entitled, so `tier/1` drops back to `:free`. (`active?/1` is suspension-only (`is_nil(suspended_at)`) and is unaffected by subscription status.) |
| `transaction.payment_failed` / `transaction.updated` | `{:ok, :checkout_stalled}` when the transaction's NEWEST payment attempt is `error` or `action_required`, else `{:ok, :ignored}`. Writes no row. | #1737. **Webhook-only coverage is blind to `action_required`:** Paddle often sends NO `transaction.updated` when a 3DS or Apple Pay attempt parks there, so the reconcile worker's stalled-checkout scan (Monitoring item 5) re-emits the same signal. Logs `checkout_payment_stalled` (or `checkout_payment_action_required`) with transaction id, customer id, method and error code, and increments `engram.paddle.checkout.stalled` tagged `reason` + `method`. **Four traps:** `payments` is cumulative, so judge the newest attempt only or the count scales with retries; the counter measures stall REPORTS, not distinct checkouts, because Paddle re-emits `transaction.updated` as a dead transaction moves on; `action_required` is a 3DS challenge in progress and every healthy EU card payment produces one, so alert on it relative to `transaction.completed` rather than per event; dunning is skipped on `origin == "subscription_recurring"` because it already arrives as `subscription.past_due` — do NOT key that on `subscription_id`, which would also drop `subscription_payment_method_change` and `subscription_charge`, both of which are live checkouts. |
| `transaction.completed` | Logs `paddle_transaction_completed` with transaction and customer id, returns `{:ok, :ignored}`. | The other half of the stalled-3DS alert (engram-infra #1157): it fires on a `checkout_payment_action_required` transaction id (from the webhook or the stalled-checkout scan) that never reaches this line. |
| `adjustment.created` / `adjustment.updated` | Finds the subscription by `subscription_id`. An approved chargeback (any size) cancels it `:immediately` through `Subscriptions.cancel/2`, then runs the canceled entity through the `subscription.canceled` clause, so the user drops to Free. An approved FULL refund does the same ONLY when it refunds the subscription's first charge: the adjustment's `transaction_id` must be the earliest `billed`/`paid`/`completed` transaction of that subscription with a non-zero grand total in the customer's history (`Client.list_transactions/1`), so a $0 trial or 100%-off checkout does not count as the first charge. That is the 14-day money-back case. A full refund of any other charge (renewal, upgrade, duplicate) keeps the plan and logs `paddle_full_refund_kept_plan`. Partial, `pending_approval`, `rejected`, credit and `chargeback_warning` change nothing; a row already canceled is a no-op. A failed history lookup returns `{:error, {:adjustment_lookup_failed, _}}`. | Paddle never cancels a subscription when its transaction is refunded. `type: "full"` is per transaction, so "full refund" alone would end a plan when support refunds one renewal. |
| anything else | `{:ok, :ignored}` + a `paddle_webhook_unhandled_event` debug line | Invoices, payment methods, etc. — out of scope for the subscription row. The debug line exists so the next gap is greppable; #1737 was invisible for four months because this branch was silent. |

**Support note (refunds).** Refunding an upgrade charge (origin subscription_update) does not change access. After approving it, change the subscription back to the previous price in Paddle with proration_billing_mode do_not_bill. Revisit if this happens more than about twice a month.

## Retries and ordering

Paddle retries a webhook only when we answer non-2xx (exponential backoff, up to 60 attempts over about two days on live), and it does not guarantee delivery order. `EngramWeb.WebhookController.paddle/2` and `Engram.Billing.upsert_from_paddle_event/1` handle both:

- **Status codes.** `{:ok, _}` (including `:ignored` and `:stale`) answers 200 and marks the `event_id` processed. An event whose `custom_data.user_id` names a user that no longer exists (a hard-deleted paying account: Paddle's follow-up updated/canceled still carry it) is `{:ok, :ignored}`: the subscription changeset declares `foreign_key_constraint(:user_id)` and the insert path maps that error to an info `paddle_webhook_owner_missing_skipped` line (`reason=owner_deleted`), 200, marked processed. A permanent error answers 200 without marking it: `:missing_user_id`, an `%Ecto.Changeset{}` (bad status, a paddle id another user holds, an unknown price on a first insert), and `{:adjustment_cancel_rejected, status}` (Paddle answered our refund cancel with a non-retryable 4xx and a follow-up read still reports the subscription live; when it reports it canceled, as after `subscription_is_canceled_action_invalid`, its state is applied instead). Paddle's lock answers stay retryable (500): 409 (`subscription_locked_renewal`, `_processing`, `_consent_review_period`), any `subscription_locked_*` code (400 `subscription_locked_pending_changes`), 429, 401/403, and a failed follow-up read, because the same payload fails the same way on every retry. Anything else (a raised exception, a DB error, an unknown reason) answers **500** without marking it, so Paddle redelivers and the handler runs again. `WebhookIdempotency.mark_processed/2` runs on success only.
- **Ordering.** `subscriptions.last_event_occurred_at` (utc_datetime_usec, nullable) stores the top-level `occurred_at` of the newest `subscription.*` event applied. An event older than it is skipped: 200, `{:ok, :stale}`, an info `paddle_webhook_stale_skipped` line with the subscription id. NULL (rows from before the column, or an event without `occurred_at`) accepts. Equal timestamps apply, because Paddle emits `subscription.updated` and `subscription.canceled` for one change at the same instant. Writes to a known row re-read it `FOR UPDATE` inside the tenant transaction, so two concurrent deliveries cannot both pass the check; the insert path puts the same check in the `ON CONFLICT ... DO UPDATE ... WHERE`.
- **First event wins the insert.** An activated/updated/past_due/canceled for a paddle id no row holds goes through the `subscription.created` path, owner from `custom_data.user_id` (every subscription event carries it). On a `user_id` conflict with a DIFFERENT paddle id, any event replaces the row when the stored row is canceled or has no paddle id; `subscription.created` also replaces it when it is not older than the row's stamp. So a late cancel, or a retried created, for a user's previous subscription cannot overwrite their new one (it is skipped as stale). One exception to the skip: a non-created event whose subscription's `created_at` is after the live row's stamp is the user's NEW subscription arriving ahead of its own created, so it answers 500 (`:awaiting_subscription_created`, warning `paddle_webhook_awaiting_created`, no error line) and Paddle retries it after the created lands. Accepted risk: with TWO live subscriptions at once (a double checkout), the order "S2 update (500), then an S1 event that moves the row's stamp past S2's `created_at`, then S2's created" skips S2's created as stale, so S2 is invisible locally until reconciliation reports it. One row per user cannot hold two live subscriptions; telling them apart would need the row to store its subscription's Paddle `created_at` (a schema change). The Try again transaction check makes the double checkout rarer.
- **Refund cancel.** The cancel we make for a refund or chargeback is run through the canceled clause stamped with the returned entity's `updated_at`, so a pre-refund `subscription.updated` delivered late is stale. A second cancel of an already canceled row (Paddle's own canceled after ours, or a replay) writes the row but emits no second `tier_downgraded`, disconnect or broadcast.

`tier` is derived from `data.items[0].price.id` matched against the four price-ID config keys (`:paddle_starter_monthly_price_id`, `:paddle_starter_annual_price_id`, `:paddle_pro_monthly_price_id`, `:paddle_pro_annual_price_id`) via `Engram.Billing.tier_from_subscription/1`. Anything unrecognized returns `{:error, :unknown_price_id}`: the upserter leaves the existing tier UNCHANGED, logs `paddle_unknown_price_id` and captures a Sentry message ("Unknown Paddle price_id, tier unchanged"). It does NOT fall back to `"starter"`. Tier comes only from the price ID, never from `custom_data`.

## Cancel reasons and the portal

Cancels go through the in-app dialog (`frontend/src/billing/cancel-panel.tsx`), which requires a reason and files `subscription_cancel_reason`. `Billing.portal_action_url/2` never hands out Paddle's `cancel_subscription` deep link (`action=cancel` gets the overview). Paddle's portal overview still offers its own cancel button, and Paddle's emails link to it, because Paddle requires customers to have a way to cancel; there is no setting to hide it. A cancel made there reaches us only as webhooks with no reason. Paddle sends `subscription.updated` with `scheduled_change.action: "cancel"` the moment an end-of-period cancel is scheduled, and `subscription.canceled` only when it takes effect (or at once, for an immediate cancel). So the check runs in two places, both through `Feedback.record_missing_cancel_reason/4`:

- **When the cancel is scheduled.** `PostHogForwarder` enqueues `Engram.Workers.CancelReasonMarker` on every `cancel_scheduled` update. The job runs 10 minutes later: the dialog sends its reason only after the cancel call returns, and the event log buffers writes, so a check on the webhook itself would race the dialog's own reason. If no reason is on file it files `subscription_cancel_reason` with `reason: "portal_no_reason"` and `source: "webhook"`. It files nothing if the user undid the cancel (`cancel_reversed`) after it was scheduled. Paddle re-sends the update while the cancel is pending. The job is unique over PENDING jobs only and a re-insert replaces its args and run time, so the last delivered schedule wins and an undo then re-cancel gets its own check. That window, not the marker lookup, is what stops near-simultaneous double filing (the event log buffers writes for a few seconds); once a job has run, a later resend's job finds the marker. `scheduled_at` is the event's `occurred_at`, so a retried delivery never looks newer than a later undo.
- **When the subscription ends** (`subscription.canceled`): the same check, which catches immediate cancels that were never scheduled. It files `"payment_failed"` instead when the sub was `past_due` (dunning). A marker filed at schedule time counts as a reason here, so nothing is filed twice.

A reason counts when it was filed since the subscription's `started_at` and after the user's last in-app reversal (`subscription_changed{kind: cancel_reversed}` with tier and status, filed by `Subscriptions.reverse_cancel/1`), so a reason for a cancel the user took back does not cover a later one, however late Paddle delivers the webhooks. A reversal made in Paddle's portal (if it offers one) is not seen. Nothing is filed when the event log is off (it would make every cancel look reasonless) or when the user row is gone. Known mislabel: a cancel made in the Paddle dashboard, or an account delete in the seconds before the user row is removed, also reads as `portal_no_reason`. The in-app dialog always files a reason at cancel time, so the marker finds it and files nothing: a picked reason, `other` when the user only typed text, or `in_app_no_reason` when they skipped the question. So `portal_no_reason` means a cancel made outside the app, and `in_app_no_reason` an in-app cancel with no answer. Insights' `cancel_reasons` counts both. A failure is logged and never fails the webhook: `cancel_reason_marker_failed` on the `subscription.canceled` path (that rescue also covers its `subscription_canceled` event), `cancel_reason_check_enqueue_failed` when the scheduled-time job cannot be enqueued.

## Trial

The 7-day card-on-file trial is configured on the Paddle **price**, not in our code: every v3 price has `trial_period: { interval: day, frequency: 7, requires_payment_method: true }` (`ops/paddle/catalog.yml`). Checkout charges $0, the subscription starts `trialing` (entitled), and Paddle emits `subscription.activated` when it converts. Engram mirrors `data.status` onto the row. `Engram.Billing.trial_days_remaining/1` computes from `current_period_end` minus `utc_now/0`.

**No plan change during a trial.** Paddle refuses any items change on a trialing subscription: tier swaps fail with `subscription_trialing_items_update_invalid_options`, cadence swaps with `subscription_new_items_not_valid`. The plan-change panel shows a trial notice instead of a picker (`frontend/src/billing/plan-change-panel.tsx`).

## Sandbox dev

```bash
export PADDLE_ENV=sandbox
export PADDLE_API_KEY=pdl_sdbx_apns_...
export PADDLE_NOTIFICATION_SECRET=pdl_ntfn_...
export PADDLE_CLIENT_TOKEN=test_...
export PADDLE_STARTER_MONTHLY_PRICE_ID=pri_01...
export PADDLE_STARTER_ANNUAL_PRICE_ID=pri_01...
export PADDLE_PRO_MONTHLY_PRICE_ID=pri_01...
export PADDLE_PRO_ANNUAL_PRICE_ID=pri_01...
```

Use the **Paddle CLI** to forward sandbox webhooks at localhost:

```
paddle notification simulate \
  --notification-type subscription.created \
  --destination http://localhost:4000/webhooks/paddle
```

For end-to-end frontend testing point Paddle.js at the sandbox by passing `environment: 'sandbox'` to `Paddle.Initialize({ token, environment })`. `GET /api/billing/config` returns `environment` so the frontend doesn't need its own env detection.

## Tests

- `Engram.Paddle.ClientMock` (Mox) — every test swaps the client via `:paddle_client` config (set in `config/test.exs`). No network in tests.
- `test/engram/billing_test.exs` — `upsert_from_paddle_event/1` covers each event type, both `user_id` flavors, and the unknown-subscription path.
- `test/engram_web/controllers/webhook_controller_test.exs` — full signature flow including replay protection.
- `test/engram_web/controllers/billing_controller_test.exs` — `/api/billing/config` payload shape.

## Monitoring (#244)

Four observability layers on the webhook + a daily reconciliation. Each is independent — losing one still gives signal from the other three.

1. **Structured logs.** `EngramWeb.WebhookController.paddle/2` sets `Logger.metadata(event_type:, event_id:)`; each line stamps `category: :billing` via `Metadata.with_category`. A handled webhook logs `paddle_webhook_received` then `paddle_webhook_ok` at `:info`. A redelivered `event_id` short-circuits as `paddle_webhook_duplicate` (`Engram.Webhooks.Idempotency`). A failed handler logs `paddle_webhook_handler_error` (or `paddle_webhook_handler_exception`) at `:error` so Sentry's LoggerHandler captures it; it answers 500 (retried) or 200 (permanent) per "Retries and ordering".

2. **`:telemetry` span.** `:telemetry.span/3` wraps `Billing.upsert_from_paddle_event/1` and emits `[:engram, :paddle, :webhook, :start | :stop | :exception]` with `event_type`, `event_id`, and (on `:stop`) `result: :ok | :error`. Declared in `EngramWeb.Telemetry.metrics/0`.

3. **Sentry capture.** DSN comes from `SENTRY_DSN`; unset disables (self-host + dev + test stay no-op). `Engram.Sentry.Scrubber` is wired as `:before_send` — strips `Sentry.Interfaces.Request.data` and recursively redacts any `extra`-map key matching email/phone/address/card/iban/pan/ssn. Smoke-test the pipeline on staging after deploy:

       mix engram.sentry.smoke

   Then look in the Sentry project for an event tagged `smoke_marker=engram.sentry.smoke`.

4. **Daily reconciliation.** `Engram.Billing.Workers.PaddleReconcile` runs at 02:00 UTC and calls `Engram.Billing.Reconciliation.run(7)`. The module fetches `Engram.Paddle.Client.list_subscriptions/1` (Paddle API, paginated) and diffs every subscription updated in the last 7 days against the local `subscriptions` table. Detects four drift kinds:

   | Kind | Meaning |
   |------|---------|
   | `:missing_local` | Paddle has the subscription, we don't (most likely a permanent-error 200, e.g. no `custom_data.user_id`, or a webhook that exhausted its retries). **Excludes `canceled` Paddle subs**, see below. |
   | `:status_mismatch` | `paddle.status != local.status`. |
   | `:tier_mismatch` | Price ID maps to a different tier than `local.tier`. |
   | `:period_mismatch` | `current_billing_period.ends_at` disagrees by more than 120 seconds. A live Paddle period with no local one is not drift: reconcile copies it into the row (`paddle_reconcile_period_repaired`, info). A sub with `current_billing_period: null` (canceled/paused) is never compared: there is no period, and access is gated on status. |

   Each entry logs at `:error` (Sentry-captured). Worker always returns `:ok` — drift is *signal*, not job failure, so Oban shouldn't retry it.

   **`:missing_local` skips `canceled` Paddle subs, by design.** A hard-deleted
   account cancels its Paddle subscription `:immediately` and then cascade-deletes
   the local `subscriptions` row with the user, so Paddle legitimately holds a
   canceled sub we have no row for — and re-ticks its `updated_at` at cancel time,
   which drags it back into the 7-day window every night for a week. That paged
   prod on 2026-09-15. Nothing is owed and no entitlement is at stake, so it is not
   drift. The skip is logged at `:info` as `paddle_reconcile_canceled_orphan_skipped`
   with the subscription id — **grep that before concluding reconciliation is
   broken.** `active`/`past_due`/`paused` with no local row still pages; that is
   the case that catches a hard-delete whose best-effort Paddle cancel failed and
   left us billing a deleted customer.

   Manual one-off:

       mix engram.billing.reconcile --days 30

   In a release shell (`bin/engram rpc`), Mix isn't available — inline the call: `Engram.Billing.Reconciliation.run(7)`.

   **Paddle list pagination: stop on `has_more`, never `next`.** `meta.pagination.next` is always present, even on the last page (it is a resume bookmark). `list_subscriptions/1` stops when `has_more != true` (`lib/engram/paddle/client/http.ex`); stopping on `next == nil` looped the reconcile worker into `pagination_loop` (PR #723). Any Paddle list mock must include `has_more` and keep a non-nil `next` on the final page, or the test passes on code that loops in prod.

5. **Stalled-checkout scan (every 5 min).** Paddle sends no webhook when a payment attempt parks at `action_required` (3DS, a dismissed Apple Pay sheet), so the stalled-checkout alert (engram-infra #1157) never saw it. `PaddleReconcile` with args `%{"scan" => "stalled_checkouts"}` calls `Reconciliation.report_stalled_checkouts/1`: it lists `ready` transactions (`Client.list_ready_transactions/1`, 30 per page, the transactions maximum) and emits `checkout_payment_action_required` through `Billing.report_checkout_transaction/2`, the same emitter the webhook path uses (`event_type: "reconcile.stalled_scan"`). Dedupe is stateless: the run anchored at tick T owns payments created in `[T-20m, T-15m)` (window width = cron interval, `Reconciliation.stalled_scan_window_seconds/0`), so ticks tile the timeline and a retry re-reads its own window.

6. **Default payment link = `https://app.engram.page/pay`.** Paddle mails `<default link>?_ptxn=<txn id>` for renewals and payment-method updates. `/pay` is public (logged-out tabs) and boots Paddle.js from `GET /api/billing/paddle-client` (client token + env only). The setting itself is in the Paddle dashboard (Checkout > Checkout configuration; set on live), not in code.

### Drift response runbook

When you see `paddle_reconciliation_drift` in Sentry or the logs:

0. If you expected a page and got silence, check for
   `paddle_reconcile_canceled_orphan_skipped` — the sub is canceled and the local
   row went with a deleted account. Only worth chasing if Paddle billed it after
   the account was deleted.
1. Note `paddle_subscription_id` and `drift_kind`.
2. `paddle get /subscriptions/<id>` (or the Paddle dashboard) to confirm Paddle's current state.
3. Replay the missed webhook event:
   - Paddle dashboard → Notifications → search by `subscription_id`.
   - Click "Replay" on the relevant event. `Billing.upsert_from_paddle_event/1` is idempotent — replays are safe.
4. Re-run `mix engram.billing.reconcile --days 7` to confirm the drift is resolved.

If a replay doesn't clear the drift, the upserter itself is failing — pull its log (search `paddle_webhook_handler_error`, same `event_id`) for the root cause.

### Self-host

Both Sentry (`SENTRY_DSN` unset) and reconciliation (`:billing_enabled` false) no-op cleanly on self-host.

## Checkout friction learnings (2026-10-24)

Verified while shipping PR #2154 (`640b0750f`, live in prod build `11be25cf7`).

- **"Incomplete" Paddle customers are abandoned checkouts**, not a bug on our side: the customer record exists, the transaction sits at `draft`/`ready` forever.
- **`action_required` stalls are webhook-silent.** See the event table and Monitoring item 5: the scan runs in `PaddleReconcile` (`lib/engram/billing/workers/paddle_reconcile.ex`, `lib/engram/billing/reconciliation.ex`), cron `4-59/5` (:x4/:x9). Worst case from attempt to alert is ~23 min: 20 min to the owning tick plus the alert's 60 s eval and 2 min pending (#2203).
- **The default payment link (`?_ptxn=`) needs a page that loads Paddle.js**; Paddle.js auto-opens checkout when `_ptxn` is in the URL. Ours is `/pay` (`frontend/src/billing/pay-page.tsx`), see Monitoring item 6.
- **Apple Pay needs `/.well-known/apple-developer-merchantid-domain-association`** served 200, `text/plain`, no redirect. `app.engram.page` is the Cloudflare Worker `engram-frontend`; `frontend/worker/index.ts` serves the file and 404s every other `/.well-known` path. Before, the SPA fallback answered HTML 200 and Apple Pay stalled. Staging routes `/.well-known` to Phoenix (JSON 404), so staging cannot prove this; check prod with `curl -sI`.
- **Currency conversion is off, so every price is USD.** Local methods (Pix = BRL, UPI = INR, Korean cards = KRW) never show at checkout even when "enabled". iDEAL, Bancontact, BLIK, MB WAY and WeChat Pay do not support subscriptions at all.
- **A closed mid-payment checkout waits 30 s, then Paddle decides.** After `checkout.payment.initiated` and a close with no `checkout.completed`, the page waits `CONFIRM_WINDOW_MS` (30 s) for the activation push. Our webhook can sit in Paddle's backoff longer than that, so "Try again" first asks `GET /api/billing/checkout-transactions/:id` (Paddle's status for that transaction, owner checked via `custom_data.user_id`, status only): `billed`/`paid`/`completed` shows the payment-received banner instead of a second checkout. Residual risk: a buyer who closes before `payment.initiated` fires has no transaction id to check.
- **Paddle list API from curl needs `-g`**: `order_by=created_at[DESC]` has `[ ]`, which curl otherwise treats as a URL glob.

## What this doc deliberately does not cover

- Affiliate-platform-specific integration (Rewardful etc.). Configured in their dashboards, not in our code.
- Annual prices ($70/yr Starter, $140/yr Pro). Wired via the `*_annual_price_id` config keys; surfaced under `price_ids.{starter,pro}.annual` in `GET /api/billing/config`.
