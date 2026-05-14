# Paddle integration

How Engram talks to Paddle Billing. Owner: billing / monetization. Status: backend wired (`feat/paddle-cutover`), frontend overlay still to land.

## Why Paddle

- **Merchant of Record.** Paddle collects + remits VAT, GST, and US sales tax on our behalf. No tax-engine, no per-jurisdiction registration, no compliance audits. For a global SaaS this is the single biggest reason to choose Paddle over Stripe.
- **Affiliate-friendly.** Paddle has native integrations with Rewardful, FirstPromoter, Tapfiliate, and Impact. Affiliate referral IDs ride along on the checkout via `custom_data` and surface on every subscription webhook — we persist them on `subscriptions.custom_data` so revenue attribution is queryable.
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
       └─ anything else                  → {:ok, :ignored}
```

## Module map

| Module | Purpose |
|--------|---------|
| `Engram.Paddle.Client` (`lib/engram/paddle/client.ex`) | Behaviour declaring `create_customer_portal_session/1`. `impl/0` reads `:paddle_client` config so tests can swap in Mox. |
| `Engram.Paddle.Client.HTTP` (`lib/engram/paddle/client/http.ex`) | Default Req-based impl. Base URL switches on `:paddle_env` (`production` → api.paddle.com, else sandbox-api.paddle.com). |
| `Engram.Billing` (`lib/engram/billing.ex`) | `upsert_from_paddle_event/1`, `create_portal_session/1`, `tier/1`, `active?/1`, `trial_days_remaining/1`. |
| `EngramWeb.WebhookController.paddle/2` | Signature verify + dispatch to `upsert_from_paddle_event/1`. |
| `EngramWeb.BillingController` | `:status`, `:config` (overlay payload), `:customer_portal`. |

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
  items: [{ priceId: cfg.price_ids.starter, quantity: 1 }],
  customer: { email: cfg.customer_email },
  customData: {
    ...cfg.custom_data,          // { user_id: 42 }
    affiliate_ref: 'rf_abc',     // from cookie / query param
    utm_source: 'twitter',
    utm_campaign: 'launch'
  },
  settings: { successUrl: 'https://engram.app/billing?status=success' }
});
```

Whatever the overlay sends becomes `data.custom_data` on every subscription webhook for that subscription. The backend persists the full map on `subscriptions.custom_data` (JSONB), keyed off the initial `subscription.created` event. Subsequent updates leave `custom_data` untouched so the original attribution survives plan changes.

`user_id` resolution accepts either integer or stringified integer — Paddle returns JS-typed values that arrive over the wire as strings in some configurations.

## Event lifecycle

| Event type | What we do | Why |
|------------|------------|-----|
| `subscription.created` | Insert row (or upsert on `user_id` conflict). Populates `paddle_customer_id`, `paddle_subscription_id`, `tier`, `status`, `current_period_end`, `custom_data`. | First touch — bind the Paddle entities to the user. |
| `subscription.activated` | Update `status`, `tier`, `current_period_end` by `paddle_subscription_id`. | Fires when trial converts to paid. |
| `subscription.updated` | Same as activated. | Plan change, billing cycle roll, dunning recovery. |
| `subscription.past_due` | Same as activated; status becomes `"past_due"`. | Card declined, retry in progress. We still gate access in `active?/1` since past-due remains within the grace window. |
| `subscription.canceled` | Status becomes `"canceled"`. | End of life. `active?/1` returns false. |
| anything else | `{:ok, :ignored}` | Transactions, invoices, payment methods, etc. — out of scope for the subscription row. |

`tier` is derived from `data.items[0].price.id` matched against `:paddle_starter_price_id` / `:paddle_pro_price_id` config; anything unrecognized falls back to `"starter"`.

## Trial

The 7-day card-on-file trial is configured on the Paddle **price**, not in our code. Paddle creates the subscription with `status: "trialing"` and emits `subscription.activated` when it converts. Engram simply mirrors `data.status` onto the row. `Engram.Billing.trial_days_remaining/1` computes from `current_period_end` minus `utc_now/0`.

## Sandbox dev

```bash
export PADDLE_ENV=sandbox
export PADDLE_API_KEY=pdl_sdbx_apns_...
export PADDLE_NOTIFICATION_SECRET=pdl_ntfn_...
export PADDLE_CLIENT_TOKEN=test_...
export PADDLE_STARTER_PRICE_ID=pri_01...
export PADDLE_PRO_PRICE_ID=pri_01...
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

## What this doc deliberately does not cover

- Frontend wiring of Paddle.js (marketing site + app). Owned by the frontend rewrite.
- Affiliate-platform-specific integration (Rewardful etc.). Configured in their dashboards, not in our code.
- Annual prices ($50/yr, $100/yr). Same wiring; just add the price IDs when they exist in Paddle.
