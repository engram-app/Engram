# SPA flatten follow-ups

Leftover items from PR #103 review (refactor: drop `/app` URL prefix). None block users today — all are hardening, DRY, or doc cleanups. Group into 2–3 small PRs.

## Group A — SPA hardening

### A1. React Router NotFound page
- **File:** `frontend/src/router.tsx`
- **What:** add `{ path: '*', element: <NotFoundPage /> }` as a top-level route, plus a minimal `not-found.tsx` component with a "back to home" link.
- **Why:** today, in-SPA typos (e.g. `/setting`, `/notess/foo`) render blank — React Router silently mounts an empty outlet. Users blame the product; we get no telemetry.
- **Effort:** ~10 min.

### A2. Content-Security-Policy on SPA responses
- **File:** `lib/engram_web/router.ex` — `:spa` pipeline
- **What:** add a CSP header. Needs to allow Clerk, Stripe.js, and the SPA bundle. Rough start:
  ```
  default-src 'self';
  script-src 'self' 'unsafe-inline' https://*.clerk.accounts.dev https://js.stripe.com;
  style-src 'self' 'unsafe-inline';
  img-src 'self' data: https:;
  connect-src 'self' https://*.clerk.accounts.dev wss://app.engram.page;
  frame-ancestors 'none';
  ```
- **Why:** `x-frame-options: DENY` is already set, but a real CSP blocks injected `<script>` and exfil channels on the OAuth consent UI specifically.
- **Effort:** ~30 min including testing Clerk + Stripe flows don't break.

## Group B — DRY + drift guards

### B1. Centralize Clerk URL constants
- **Files:** `frontend/src/auth/clerk-auth-provider.tsx`, `frontend/src/router.tsx`, `frontend/src/auth/sign-in.tsx`
- **What:** new `frontend/src/routes.ts` exporting `SIGN_IN`, `SIGN_UP`, `OAUTH_CONSENT`, etc. Import in all three call sites.
- **Why:** today the strings `/sign-in`, `/sign-up`, `/oauth/consent` are typed by hand in multiple files. Rename in one place, forget the other → silent breakage (Clerk redirect to a path that doesn't render).
- **Effort:** ~15 min.

### B2. SpaController boot-time integrity check
- **File:** `lib/engram_web/controllers/spa_controller.ex` (or new `Engram.SpaIntegrity` module called from `Engram.Application.start/2`)
- **What:** at app start, read `priv/static/app/index.html`, extract every `src=` / `href=` under `/assets/...`, and assert each file exists on disk. Raise loudly on mismatch.
- **Why:** stale Docker layer cache or a botched release tarball ships an index.html referencing assets that aren't there. Plug.Static + SPA catch-all falls through, browser MIME-fails on `<script>` tags, blank app, zero log signal. Boot-time check turns it into a release-pipeline error instead of a user-visible white page.
- **Effort:** ~20 min.
- **Related:** `docs/context/docker-build-cache-pitfalls.md` — same class of issue.

### B3. `safeReturnTo` backslash guard
- **File:** `frontend/src/auth/sign-in.tsx:8-12`
- **What:** add `if (raw.startsWith('/\\')) return '/'` — some URL parsers treat `/\evil.com` like `//evil.com` (open redirect).
- **Why:** defense-in-depth; preexisting code, not introduced by PR #103 but flagged in review.
- **Effort:** 1 min + a unit test.

## Group C — Doc cleanups

### C1. `dev-iteration-loop.md` TODO
- **File:** `docs/context/dev-iteration-loop.md:68`
- **What:** document the real `app.engram.page` hosting path (Cloudflare → FastRaid nginx → Phoenix `:4000`). The TODO still asks how `engram.ras.band` resolves — that's stale; the active host is now `app.engram.page` after the marketing split.
- **Effort:** ~5 min.

### C2. OAuth controller docstring wording
- **File:** `lib/engram_web/controllers/oauth_authorize_controller.ex` moduledoc + `router.ex:51-53`
- **What:** replace "validates client credentials + PKCE" with "validates client_id + redirect_uri + PKCE". DCR mints public PKCE clients with no `client_secret`, so "credentials" is misleading.
- **Effort:** 1 min.

## Suggested PR order

1. **`refactor: SPA hardening (NotFound + CSP)`** — Group A. User-visible.
2. **`refactor: centralize SPA route constants + boot integrity check`** — Group B.
3. **`docs: scrub stale /app references + clarify hosting`** — Group C.

## Not on this list (decided to defer or skip)

- Historical plan docs under `docs/superpowers/plans/` still reference `/app/oauth/authorize`. Convention is to leave plan docs as point-in-time records; not worth churning.
- `frontend/e2e/` integration test for the full OAuth handshake (302 → consent UI mounts → POST consent). Worth doing eventually but bigger than a follow-up — needs a Phase 7 e2e harness.
