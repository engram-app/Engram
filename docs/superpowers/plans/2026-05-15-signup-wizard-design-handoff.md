# Signup wizard design — session handoff

**Status:** brainstorming paused mid-discovery before /compact. Resume by re-reading this doc, then continue with the clarifying questions in the "Resume here" section.

## What just shipped (background)

- **PR #141** (`feat/paddle-overlay` → `main`): frontend overlay rewrite. Six commits:
  - `b46c292` feat(paddle): wire frontend overlay to /api/billing/config
  - `09cc262` chore: paddle-docs MCP + plan doc
  - `8b3aad7` chore: Makefile ported from engram-workspace
  - `723a565` feat(paddle): allow Paddle.js in CSP
  - `f83264d` chore: bump version to 0.5.106
- Backend cutover already on main as #132 (Paddle MoR end-to-end).
- Tested end-to-end against Paddle sandbox: real card → transaction → `subscription.created` webhook → DB row → UI flipped. Subscription `sub_01krn5g6t9stkvmkzwq2r1vh50` for user 14 lives in the sandbox.

## Local Paddle sandbox state (live but ephemeral)

| What | Value |
|---|---|
| Notification destination | `ntfset_01krn44f739kqzsdpvmac43k4w` (pointed at a cloudflared tunnel URL that dies when the process stops) |
| Starter product / price | `pro_01krn42qx396agpy5t03tcd140` / `pri_01krn432tn18s0pf2yrx8nr8z2` |
| Pro product / price | `pro_01krn42r4wgxbay4rrc38hj7pt` / `pri_01krn4330hj8jfespdafc25dqt` |
| Client-side token | `test_e08f11beb9994342d34323c2f02` |
| All values | also in `.env.local` (gitignored) |

Tunnel + Phoenix may not be running by the time this doc is read. `make dev` to restart Phoenix; relaunch `cloudflared tunnel --url http://localhost:4000` and `PATCH /notification-settings/{id}` with the new URL if you need real webhook delivery again.

## The next design problem — 3-phase signup wizard

The user (Todd) wants a forced three-step flow before a new user can use the app:

1. **Account creation** — already exists via Clerk (`/sign-up`) or local-auth (`/sign-up` for non-Clerk envs).
2. **User agreement** — accept TOS / Privacy. Nothing like this exists in the codebase today.
3. **Payment** — `/billing` already works; user picks Starter or Pro, completes Paddle overlay, lands on `subscription.created` → DB row with `status: trialing`.

Current gating is auth-only. After signup, Clerk redirects to `/` (the dashboard); nothing forces TOS or payment. We need to introduce gating that funnels new users through agreement + payment before they can read/write notes.

## Codebase facts already gathered (skip re-discovery)

- `frontend/src/router.tsx` — `AuthGuard` wraps the app shell; today it only checks `isSignedIn`. No subscription / agreement gate exists.
- `frontend/src/auth/sign-up.tsx` — Clerk's hosted `<SignUp routing="hash" forceRedirectUrl="/">` widget. Local-auth has its own `<LocalSignUp />` in `frontend/src/auth/local-sign-up.tsx`.
- `frontend/src/billing/billing-page.tsx` — what PR #141 just rewrote. Renders plan cards when `tier === 'none'`, flips to "Free Trial" badge + Manage button when a subscription exists.
- `frontend/src/api/queries.ts` — `useBillingStatus()` and `useBillingConfig()` already there; backend exposes `/api/billing/status`, `/api/billing/config`, `/api/billing/portal`.
- `frontend/src/layout/app-layout.tsx` (not yet read in this session) — the chrome behind `AuthGuard`.
- **No TOS / Privacy tracking in the codebase.** Grep for `terms`, `tos`, `agreement`, `privacy` only turns up OAuth consent code (unrelated). New migration + new column on `users` (or new `user_agreements` table) needed.
- Pricing tiers from `CLAUDE.md`: Starter $5/mo, Pro $10/mo, 7-day free trial, card required.
- `AuthGuard` redirects to `/sign-in?return_to=...` when not signed in. Pattern to extend: add a `BillingGate` / `OnboardingGate` that redirects to `/onboard` when subscription/agreement is missing.

## Resume here — clarifying questions I was about to ask

Ask these one at a time per the brainstorming skill (`superpowers:brainstorming`). The user already **declined the visual companion** for this design session.

1. **Enforcement layer.** Should the gate live in the frontend (route guard) or also in the backend (plug that 403s on every authenticated route until the user has both agreement + active subscription)? Frontend-only is faster to ship and reversible; backend is the only way to be airtight (a determined user can bypass route guards). Tradeoff: speed/iteration vs. genuine enforcement.
2. **Wizard location.** Dedicated `/onboard` route with a multi-step UI, or inline modal that appears over the dashboard, or three separate pages (`/onboard/welcome`, `/onboard/agreement`, `/onboard/billing`)? Dedicated route is the easiest to bookmark/share and matches the existing routing pattern.
3. **Existing users.** What happens to current signed-in users on `main` who haven't accepted TOS? Grandfather them in, or force-prompt the agreement step on next login? (Payment isn't a concern for them — most are dev accounts.)
4. **Free tier / skipping payment.** CLAUDE.md says SaaS-only at launch, but a 7-day trial implies card-required. Is "skip payment" ever allowed (e.g., admin override, comp accounts), or is every account required to enter a card?
5. **TOS versioning.** Do we need to track which version of the TOS the user accepted, and re-prompt when we publish a new version? If yes, that shapes the data model (`user_agreements` table with `version` column) and adds a "you must re-accept" gate. If no, simpler boolean `agreed_at: datetime` column on `users` is enough.
6. **Auth providers.** The agreement step needs to work for both Clerk and local-auth. Anything else to consider (SSO, magic links)? Currently only those two.

## Likely shape of the design (preview, not yet validated)

- **Data model**: new `users.terms_accepted_at` (or richer `user_agreements` table if versioning matters). Subscription state is already in `subscriptions`.
- **Backend gate**: extend `EngramWeb.Plugs.AuthRequired` (or add new `OnboardingRequired` plug) — returns 403 `{error: "onboarding_required", missing: ["terms", "subscription"]}` from `/api/*` routes if either is missing.
- **Frontend gate**: new `OnboardingGate` component above `AppLayout` in the route tree. Queries `/api/onboarding/status` (new endpoint), redirects to `/onboard/agreement` or `/onboard/billing` as needed.
- **Onboarding routes**: nested under `AuthGuard` (signed-in only, no `OnboardingGate`). Three pages or three steps in one page.
- **TOS content**: hosted at `/legal/terms` (new static markdown route) so the agreement page can link to it.

## After answering the clarifying questions

Proceed through the brainstorming checklist:

1. Propose 2–3 approaches with tradeoffs.
2. Present design in sections, get approval per section.
3. Write spec to `docs/superpowers/specs/2026-05-15-signup-wizard-design.md`.
4. Spec self-review (placeholders / contradictions / scope / ambiguity).
5. Ask Todd to review the spec.
6. Hand off to `superpowers:writing-plans`.

**Do not implement during brainstorming.** The hard gate is in the brainstorming skill.
