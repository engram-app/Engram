# Context Doc: Billing tier contract (backend → frontend)

_Last verified: 2026-05-26_

## Status
Working — fixed in PR #309 (`fix/onboarding-flow`).

## What This Is
The `tier` value the backend reports for a user, and the rule any consumer (the
React billing UI, plugin, etc.) must follow when interpreting it. A drift here
made the onboarding billing step render blank.

## The contract
`GET /api/billing/status` returns `tier` from `Engram.Billing.tier/1`
(`lib/engram/billing.ex`). Possible values:

`free | trial | starter | pro`  (plus `none` historically — see gotcha)

**A user with no/canceled/expired subscription is `:free`, NOT `:none`.** Pricing
v2 changed the default. `active?/1` is true only for `active | past_due |
trialing` subscriptions.

## Rule for consumers
- Handle **every** tier value, including `free`. A label/lookup keyed only on a
  subset silently renders empty for the missing key.
- Derive "this user needs to pick a paid plan" from **`!billing.active`**, not
  from `tier === 'none'` (or any single tier string). `active` is the
  authoritative flag and self-heals as tiers are added/renamed.

## Gotchas
- **`tier === 'none'` is stale.** Before pricing v2 a subscriptionless user was
  `none`; now they're `free`. Frontend code (`TIER_LABELS`, `needsSubscription`,
  the `BillingStatus.tier` TS union) written against `none` produced:
  - an **empty plan badge** (`TIER_LABELS["free"]` was `undefined`), and
  - **hidden plan cards** (`needsSubscription = tier === 'none'` was false for
    `free`), so the onboarding billing step looked blank/broken.
- **Onboarding still gates on a paid plan.** `Engram.Onboarding.status/1` sets
  `subscription_ok = Billing.active?(user)`, and `free` is NOT active — so a
  brand-new user sits on the billing step until they start a trial. `free` is the
  "not chosen yet" state during onboarding, not a finish state.
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
- `docs/context/pricing-v2-server-side-enforcement-audit.md` (server-side tier enforcement).
