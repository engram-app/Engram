# Paddle frontend overlay rewrite — handoff

**Status:** session interrupted before code changes started. No branch cut yet. Working dir on `chore/app-token-client-id` (unrelated CI cleanup).

## Context

Paddle backend cutover is **done and merged on main** (PR #132, 2026-05-14). All Stripe code/cols/deps removed; `Engram.Paddle.Client` behaviour + Req HTTP impl, `Engram.Billing` event upserter, webhook signature verify, three billing endpoints all wired and tested.

The frontend `frontend/src/billing/billing-page.tsx` is **stale** — still calls dead Stripe-style endpoints (`POST /billing/checkout-session`, `GET /billing/portal`) and renders "Manage subscription in Stripe" copy. This blocks revenue.

See `docs/context/paddle-integration.md` for the full backend spec, webhook signature format, `custom_data` contract, and event lifecycle table.

## Backend endpoints the frontend must consume

Defined in `lib/engram_web/router.ex:152-157` (under `/api`, requires auth):

| Method | Path | Returns |
|--------|------|---------|
| GET | `/api/billing/status` | `{tier, active, trial_days_remaining, subscription: {status, tier, current_period_end} \| null}` |
| GET | `/api/billing/config` | `{client_token, environment, price_ids: {starter, pro}, customer_email, custom_data: {user_id}}` |
| GET | `/api/billing/portal` | `{url}` (controller action `:customer_portal`) |

Note: there is **no** `/billing/checkout-session` endpoint anymore. The whole point of Paddle is the overlay opens client-side after fetching `/api/billing/config`.

## Decisions reached this session

1. **Paddle.js loader:** `@paddle/paddle-js` npm package (typed React-friendly wrapper, version-pinned). Not the CDN script tag.
2. **PR scope:** full overlay rewrite in one PR — `billing-page.tsx` end-to-end, including config fetch, `Paddle.Initialize`, `Paddle.Checkout.open`, portal handler swap, and Stripe copy strip. Affiliate/utm cookie capture deferred to a follow-up.
3. **Test path:** ship the rewrite without unit tests, add vitest infra in a separate repo-wide PR. Frontend has zero unit-test infrastructure today (only Playwright e2e in `e2e/`). Backend already has thorough Paddle coverage. Manual verify via Paddle sandbox + `paddle notification simulate` is acceptable for this PR.
4. **Branch:** cut `feat/paddle-overlay` off `main` (NOT off the current `chore/app-token-client-id` branch).

## Concrete plan (resume here)

1. Restart session so the new `paddle-docs` MCP server (now in repo `.mcp.json`) loads. First call will trigger Kapa.ai OAuth in browser.
2. **Validate decisions against the MCP** before touching code — especially:
   - Confirm `@paddle/paddle-js` `initializePaddle({ token, environment })` API signature.
   - Confirm `Paddle.Checkout.open({ items: [{ priceId, quantity }], customer: { email }, customData, settings: { successUrl } })` is the current shape.
   - Confirm `customer_portal` is fetched server-side (Paddle API → returns hosted URL) and not opened via paddle.js — this is what `lib/engram/paddle/client/http.ex` already implements.
   - Look for any newer recommended pattern (e.g. `Paddle.Update`, dynamic price discovery) we should adopt.
3. From `main`: `git switch main && git pull && git switch -c feat/paddle-overlay`.
4. `cd frontend && npm install @paddle/paddle-js`.
5. Add `useBillingConfig()` query in `frontend/src/api/queries.ts` mirroring existing `useBillingStatus()` (line 138).
6. Rewrite `frontend/src/billing/billing-page.tsx`:
   - `useEffect` → call `initializePaddle({ token, environment })` once config is loaded; cache the resolved Paddle instance.
   - `handleCheckout(tier)` → `paddle.Checkout.open({ items: [{ priceId: cfg.price_ids[tier], quantity: 1 }], customer: { email: cfg.customer_email }, customData: cfg.custom_data, settings: { successUrl: window.location.origin + '/billing?status=success' } })`.
   - `handlePortal()` → keep `GET /billing/portal` (api client base prepends `/api`); confirm path resolves to `/api/billing/portal` not the old `/billing/portal`.
   - Strip "Manage subscription in **Stripe**" → "Manage subscription".
7. Manual verify against Paddle sandbox:
   - Set `PADDLE_*` env vars per `docs/context/paddle-integration.md#sandbox-dev`.
   - Open `/billing` in dev, click Start free trial → overlay should appear.
   - `paddle notification simulate --notification-type subscription.created --destination http://localhost:4000/webhooks/paddle` → confirm row inserted with `custom_data.user_id`.
8. Open PR. Title: `feat(paddle): wire frontend overlay to /api/billing/config`. Body: link to this doc + PR #132.

## Key files to touch

- `frontend/src/billing/billing-page.tsx` — full rewrite
- `frontend/src/api/queries.ts` — add `useBillingConfig()`
- `frontend/package.json` / `package-lock.json` — `@paddle/paddle-js` dep
- (no backend changes)

## Out of scope for this PR

- Affiliate/utm cookie capture (separate PR — needs cookie reader util + customData merge logic)
- Marketing-site checkout (frontend rewrite owns it)
- Annual price IDs ($50/yr, $100/yr) — wire when prices exist in Paddle dashboard
- Vitest infra bootstrap — separate repo-wide PR
- Production env wiring on Fly + Paddle dashboard webhook URL registration

## Where the truth lives

- Backend integration spec: `docs/context/paddle-integration.md`
- This handoff: `docs/superpowers/plans/2026-05-14-paddle-frontend-overlay.md`
- Live Paddle docs: `paddle-docs` MCP server (HTTP, `https://paddlehq.mcp.kapa.ai`, repo `.mcp.json`) — **use this to validate the call shapes above before implementing**
