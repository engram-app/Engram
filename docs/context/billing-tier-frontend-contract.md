# Context Doc: Billing tier contract (backend → frontend)

_Last verified: 2026-06-18_

## Status
Working — fixed in PR #309 (`fix/onboarding-flow`).

## What This Is
The `tier` value the backend reports for a user, and the rule any consumer (the
React billing UI, plugin, etc.) must follow when interpreting it. A drift here
made the onboarding billing step render blank.

## The contract
`GET /api/billing/status` returns `tier` from `Engram.Billing.tier/1`
(`lib/engram/billing.ex`). Possible values:

`free | starter | pro`  (plus `none` historically — see gotcha)

**A user with no/canceled/expired subscription is `:free`, NOT `:none`.** Pricing
v2 changed the default. There is **no `:trial` tier** — trial-status
subscriptions surface as their paid tier (`:starter`/`:pro`), because the
`@entitled_statuses` set is `active | trialing | past_due` (`billing.ex:148`).

**Two distinct "active" notions — do not conflate them:**
- The `active` field in the `/api/billing/status` JSON body is computed as
  **`Billing.tier(user) in [:starter, :pro]`** (`billing_controller.ex:16`). It
  means "on a paid tier". A `:free` user is `active: false` here.
- `Engram.Billing.active?/1` (`billing.ex:200`) is a **separate, suspension-only**
  predicate: `is_nil(user.suspended_at)`. It is NOT the source of the response
  field, and it is true for healthy Free users. Don't assume the JSON `active`
  flag mirrors `active?/1`; they answer different questions.

## Rule for consumers
- Handle **every** tier value, including `free`. A label/lookup keyed only on a
  subset silently renders empty for the missing key.
- Derive "this user is on a paid plan" from the response **`active`** field
  (= paid tier). To branch on "needs to pick a plan", treat `tier === 'free'`
  (or `active === false`) as the signal — but note `free` is a legitimate
  finished state outside onboarding (see gotcha), not inherently "broken".

## Gotchas
- **`tier === 'none'` is stale.** Before pricing v2 a subscriptionless user was
  `none`; now they're `free`. Frontend code (`TIER_LABELS`, `needsSubscription`,
  the `BillingStatus.tier` TS union) written against `none` produced:
  - an **empty plan badge** (`TIER_LABELS["free"]` was `undefined`), and
  - **hidden plan cards** (`needsSubscription = tier === 'none'` was false for
    `free`), so the onboarding billing step looked blank/broken.
- **Onboarding gates on tier OR an explicit Free choice.**
  `Engram.Onboarding.status/1` (`onboarding.ex:166`) computes
  `subscription_ok` as: self-host (`billing_enabled=false`) **or**
  `Billing.tier(user) in [:starter, :pro]` **or**
  `user.free_tier_accepted_at` is set. It does **not** call `active?/1`.
  A brand-new hosted user sits on the billing step until they either start a
  paid plan or click **"Continue with Free"** (which sets `free_tier_accepted_at`
  and lets the wizard advance). So `free` IS a valid finish state for onboarding —
  it just requires the explicit Free acceptance, not merely "tier == free".
- **No SPA error boundary.** An uncaught render error in a route element blanks
  the subtree (react-router default) with no console-visible app error. A blank
  step ≠ a crash here — it was a data/contract issue, confirmed by mounting the
  component in a vitest test with realistic data.
- **Tests mock `../api/queries` and `tsc` passed** even with `free` missing from
  the TS union — neither caught the drift. Only the rendered DOM + reading the
  diff surfaced it. TS unions mirroring a server contract are a silent-drift spot.

## Key files
- Backend: `lib/engram/billing.ex` (`tier/1`, `active?/1`),
  `lib/engram_web/controllers/billing_controller.ex` (`status`, `config`).
- Frontend: `frontend/src/api/queries.ts` (`BillingStatus.tier` union),
  `frontend/src/billing/billing-page.tsx` (`TIER_LABELS`, `needsSubscription`),
  `frontend/src/onboarding/onboard-billing-page.tsx`.

## References
- PR #309 (header restyle + free-tier billing fix).
- `docs/context/paddle-integration.md` (webhook/lifecycle side of subscriptions).
- Server-side tier enforcement is encoded by `mix engram.lint.no_client_only_rate_limits` (CI) — every `LimitKeys` key must have a server-side enforcement site.
