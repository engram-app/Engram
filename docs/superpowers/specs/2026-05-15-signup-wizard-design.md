# Signup wizard design

**Status:** spec, awaiting implementation plan.
**Author:** Todd (designed with Claude, brainstorming session 2026-05-15).
**Related:** `docs/superpowers/plans/2026-05-15-paddle-frontend-overlay.md` (frontend overlay, PR #141), `docs/context/paddle-integration.md`.

## Problem

New users land in the app after `/sign-up` and reach the dashboard immediately. Nothing forces them through Terms of Service acceptance or a payment plan selection. We need a forced three-phase flow:

1. **Account creation** — already exists via Clerk hosted widget or local-auth.
2. **Agreement** — accept the current Terms of Service. Nothing like this exists today.
3. **Payment** — pick a plan and complete Paddle checkout. Existing `/billing` page handles this once PR #141 lands.

The gate must work in two deployment modes:

- **SaaS** (`PADDLE_API_KEY` set): both TOS and payment are required.
- **Self-host** (`PADDLE_API_KEY` unset): wizard disabled; users go straight to the dashboard.

## Decisions

| Question | Decision |
|---|---|
| Gate enforcement | Backend plug + frontend redirect. Plug is the only real gate; frontend redirect is UX. |
| Wizard UI | Dedicated `/onboard/*` sub-routes (one route per step). |
| Existing users | Not handled. Dev DB is wipeable; no grandfather logic. |
| Payment toggle | Active iff `PADDLE_API_KEY` is set. Single boot-time config: `:engram, :billing_enabled`. |
| Self-host TOS | Skipped along with payment. Wizard is fully disabled when `billing_enabled=false`. |
| TOS versioning | Versioned `user_agreements` table. Re-prompt when current version exceeds latest accepted. |
| Auth providers | Clerk + local-auth only. No SSO/magic-link planning. |

## Architecture

### Data model

New table `user_agreements`:

| Column | Type | Notes |
|---|---|---|
| `id` | `bigserial` PK | |
| `user_id` | `bigint NOT NULL` FK → `users(id) ON DELETE CASCADE` | |
| `document` | `text NOT NULL` | e.g. `"terms_of_service"` (extensible for future `"privacy_policy"`) |
| `version` | `text NOT NULL` | e.g. `"2026-05-15"` — date-as-version, sortable lexicographically |
| `accepted_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `ip_address` | `inet NULL` | Best-effort, from `conn.remote_ip` |
| `user_agent` | `text NULL` | Best-effort, from `user-agent` header |

Indexes:

- `(user_id, document)` for lookup
- `(user_id, document, accepted_at DESC)` for "latest version per doc"

RLS policy (same pattern as other per-user tables — see `docs/context/database-schema-rls.md`):

```sql
CREATE POLICY user_agreements_isolation ON user_agreements
  FOR ALL TO engram_app
  USING (user_id = current_setting('app.current_user_id')::bigint);
```

No change to `users` table. Subscription state is already in `subscriptions` (Paddle integration).

### Config

`config/runtime.exs` reads at boot:

```elixir
config :engram,
  billing_enabled: System.get_env("PADDLE_API_KEY") != nil,
  current_tos_version: "2026-05-15"
```

`current_tos_version` must match the frontmatter version in the bundled TOS markdown file (see [TOS content](#tos-content)).

### Backend plug

New plug `EngramWeb.Plugs.RequireOnboarding`:

- Reads `Application.get_env(:engram, :billing_enabled)` at request time (test-friendly; not a compile-time constant).
- **If `billing_enabled=false`**: short-circuits, returns `conn` unchanged. Self-host bypass is a single branch.
- **If `billing_enabled=true`**:
  - Checks `user_agreements` for the latest accepted version of `"terms_of_service"`. If `accepted_version < current_tos_version` (lexicographic compare on date strings), record as missing `"terms"`.
  - Checks `subscriptions.status` for the current user. If not in `["trialing", "active", "past_due"]`, record as missing `"subscription"`.
  - If any missing: `conn |> put_status(403) |> json(%{error: "onboarding_required", missing: [...]}) |> halt()`.
  - Otherwise: returns `conn` unchanged.

Placement in `lib/engram_web/router.ex`:

- Vault-scoped pipeline (the one that gates notes/search/sync/etc.) — add `RequireOnboarding` **after** `Auth` and `RotationLockCheck`, **before** `VaultPlug`.
- The user-scoped pipeline above it (line 124-163 today) deliberately does **not** include `RequireOnboarding`. Endpoints there (`/me`, `/billing/*`, `/onboarding/*`, vault management) must remain reachable during onboarding so the wizard can function.

### Backend endpoints

All under the user-scoped authenticated pipeline (after `Auth + RotationLockCheck`, exempt from `RequireOnboarding`):

**`GET /api/onboarding/status`** — returns wizard state.

```json
{
  "enabled": true,
  "terms_ok": false,
  "subscription_ok": false,
  "current_tos_version": "2026-05-15",
  "next_step": "agreement"
}
```

`next_step` is one of `"agreement" | "billing" | "done"`. Order: terms first, then subscription. When `enabled=false`: returns `{enabled: false, next_step: "done"}` (frontend skips the redirect entirely).

**`POST /api/onboarding/accept-terms`** — records acceptance.

```json
// Request
{ "version": "2026-05-15" }

// Response 201
{ "accepted_at": "2026-05-15T18:23:11Z", "version": "2026-05-15" }
```

The endpoint records `ip_address` from `conn.remote_ip` and `user_agent` from headers. Server validates `version` matches `Application.get_env(:engram, :current_tos_version)` — accepting an outdated version is a 422.

No `decline` endpoint. Users either accept or close the tab.

### Frontend gate

New component `frontend/src/onboarding/onboarding-gate.tsx`:

- Wraps `<AppLayout>` in the route tree.
- Calls `useOnboardingStatus()` (TanStack Query, `staleTime: Infinity`).
- If `enabled && next_step !== "done"`: `<Navigate to={`/onboard/${next_step}`} replace />`.
- Otherwise: renders children.

The query is invalidated:

- After `POST /api/onboarding/accept-terms` succeeds.
- After Paddle webhook arrives (existing channel push in `frontend/src/billing/`).

Route structure in `frontend/src/router.tsx` (conceptual — actual code will mirror existing patterns):

```
<AuthGuard>
  <Routes>
    {/* No OnboardingGate — wizard would redirect-loop */}
    <Route path="/onboard" element={<OnboardLayout />}>
      <Route index element={<OnboardRedirect />} />
      <Route path="agreement" element={<AgreementPage />} />
      <Route path="billing" element={<OnboardBillingPage />} />
    </Route>

    {/* Everything else is gated */}
    <Route element={<OnboardingGate><AppLayout /></OnboardingGate>}>
      <Route path="/" element={<DashboardPage />} />
      {/* ... existing routes ... */}
    </Route>
  </Routes>
</AuthGuard>
```

SPA whitelist in `lib/engram_web/router.ex` SPA scope (line 232-246) must include:

```elixir
get "/onboard", SpaController, :index
get "/onboard/*path", SpaController, :index
```

### Frontend components

- **`OnboardLayout`** — shared chrome: logo, step indicator ("Step 2 of 2"), logout button. Wraps `/onboard/*` children.
- **`OnboardRedirect`** — renders nothing; reads status and redirects to `agreement` or `billing` based on `next_step`. Handles the case where the user lands on `/onboard` directly.
- **`AgreementPage`** — scrollable TOS markdown content + "I agree to the Terms of Service" checkbox + "Continue" button. On submit, calls `useAcceptTerms()` mutation → invalidates onboarding-status query → router re-evaluates → redirects to `/onboard/billing`.
- **`OnboardBillingPage`** — thin wrapper around the existing `frontend/src/billing/billing-page.tsx`. Same plan-picker UI, same Paddle overlay. The wrapper hides the "back to dashboard" link (since there's no dashboard yet) and shows "waiting for Paddle…" spinner once checkout completes, refetching status until `subscription_ok=true`, then redirects to `/`.

### Queries hook

New in `frontend/src/api/queries.ts`:

```ts
export interface OnboardingStatus {
  enabled: boolean
  terms_ok: boolean
  subscription_ok: boolean
  current_tos_version: string
  next_step: 'agreement' | 'billing' | 'done'
}

export function useOnboardingStatus() {
  return useQuery({
    queryKey: ['onboarding', 'status'],
    queryFn: () => api.get<OnboardingStatus>('/onboarding/status'),
    staleTime: Infinity,
  })
}

export function useAcceptTerms() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (version: string) =>
      api.post('/onboarding/accept-terms', { version }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['onboarding', 'status'] }),
  })
}
```

### TOS content

Bundled as a markdown file: `frontend/src/legal/terms-of-service.md`, imported as a raw string (Vite supports `?raw` import suffix).

Frontmatter:

```markdown
---
version: 2026-05-15
---

# Terms of Service

...
```

The version in the frontmatter MUST match `Application.get_env(:engram, :current_tos_version)`. A pre-commit hook or CI check can enforce this later; for v1 it is a manual coordination.

When the TOS content changes:

1. Bump the version in both the markdown frontmatter and `config/runtime.exs`.
2. Existing users with `accepted_version < new_version` automatically get re-prompted on next request.
3. The agreement-only re-prompt is the same component; subscription gate is already satisfied so the wizard jumps straight to `/onboard/agreement` and back to `/` after acceptance.

## Data flow

### New user, SaaS mode

```
User completes /sign-up (Clerk or local-auth)
  → redirected to /
  → OnboardingGate reads GET /api/onboarding/status
  → response: { enabled: true, terms_ok: false, subscription_ok: false, next_step: "agreement" }
  → Navigate to /onboard/agreement
  → User reads TOS, checks box, clicks Continue
  → POST /api/onboarding/accept-terms { version: "2026-05-15" }
  → 201 created; invalidate status query
  → OnboardRedirect reads fresh status: next_step: "billing"
  → Navigate to /onboard/billing
  → User picks Starter or Pro plan, completes Paddle overlay checkout
  → Paddle webhook arrives → DB row inserted → channel push to frontend
  → Status query refetches: subscription_ok: true, next_step: "done"
  → Wrapper redirects to /
  → OnboardingGate sees next_step: "done", renders <AppLayout>
```

### Returning user, SaaS mode, TOS still current and subscribed

```
User signs in
  → redirected to /
  → OnboardingGate reads status
  → next_step: "done"
  → renders <AppLayout> immediately (one status fetch, cached forever in session)
```

### Self-host mode

```
User completes /sign-up
  → redirected to /
  → OnboardingGate reads status
  → enabled: false, next_step: "done"
  → renders <AppLayout> immediately
```

### TOS version bumped after user accepted

```
User signs in (existing subscription)
  → OnboardingGate reads status
  → enabled: true, terms_ok: false, subscription_ok: true, next_step: "agreement"
  → Navigate to /onboard/agreement
  → User accepts new version
  → next_step: "done", redirect to /
```

## Error handling

| Scenario | Behavior |
|---|---|
| User clears localStorage mid-wizard | Status endpoint is idempotent; gate re-redirects to the right step. |
| Paddle webhook delayed | `/onboard/billing` polls status (TanStack Query refetch-on-focus) until `subscription_ok=true`. UI shows "Finishing setup…". |
| Webhook never arrives | After 30s, surface a "Still waiting on Paddle. Refresh, or contact support." message. Manual recovery via Paddle dashboard webhook replay. |
| User opens app on a second device mid-wizard | Same status endpoint, same redirect logic. No real-time broadcast needed for v1. |
| Paddle service outage during checkout | Existing Paddle overlay surfaces the error. User stays on `/onboard/billing`. |
| User POSTs accept-terms with stale version | 422; frontend reloads to fetch fresh `current_tos_version`. Edge case (TOS bumped between page-load and submit). |
| User reaches `/api/notes` before completing wizard | 403 `{error: "onboarding_required", missing: [...]}`. Frontend's global API error handler redirects to `/onboard`. |

## Testing strategy

| Layer | What is tested | Tooling |
|---|---|---|
| Unit — plug | `RequireOnboarding` plug: `billing_enabled` toggle, missing-terms, missing-sub, both-OK. Stubs `Application.get_env`. | ExUnit + `Plug.Test` |
| Unit — context | `Engram.Onboarding.status/1`, `accept_terms/3` with ExMachina factories. RLS-isolated. | ExUnit + ExMachina |
| Integration — router | ConnCase tests: `GET /api/notes` returns 403 with `missing: ["terms"]` when user hasn't accepted; returns 200 after agreement + subscription. | ExUnit + ConnCase |
| Frontend — component | RTL tests for `OnboardingGate` with mocked queries; verifies redirect to `agreement`/`billing`/null. | Vitest + RTL |
| E2E — sandbox | `e2e/tests/test_onboarding.py`: register → expect 302 to `/onboard/agreement` → accept terms → expect redirect to `/onboard/billing`. Paddle overlay itself stays manual. | pytest + Docker stack |

**TDD order** (for the implementation plan):

1. Migration + `user_agreements` schema + RLS test.
2. `Engram.Onboarding` context module + tests.
3. `RequireOnboarding` plug + tests.
4. `/api/onboarding/*` endpoints + ConnCase tests.
5. `useOnboardingStatus` + `useAcceptTerms` hooks + tests.
6. `OnboardingGate` + `OnboardLayout` + `AgreementPage` + `OnboardBillingPage` components.
7. Router wiring (backend + frontend).
8. E2E test.

## Out of scope (explicit YAGNI)

- TOS re-prompt UI for old users — dev DB is wipeable; first-time TOS only for v1.
- Privacy Policy as a separate document — single `terms_of_service` document for v1.
- Skip / decline flow — no way to refuse the TOS; user can only accept or close the tab.
- Real-time broadcast to other devices when wizard completes on one device — devices refetch on focus, that is sufficient.
- Admin override / comp accounts — manual DB insert into `subscriptions` is the escape hatch for v1.
- CI enforcement that markdown frontmatter version matches `config/runtime.exs` — manual coordination for v1.
- SSO / magic-link signup paths — not in scope; revisit when Engram supports them.

## Open coordination items

- TOS content itself does not exist yet. Body of `frontend/src/legal/terms-of-service.md` needs to be written before this can go to production. Initial version `"2026-05-15"` is a placeholder string for the schema.

## Files touched (preview)

**Backend:**

- `priv/repo/migrations/<timestamp>_create_user_agreements.exs` *(new)*
- `lib/engram/onboarding.ex` *(new — context module)*
- `lib/engram/onboarding/agreement.ex` *(new — Ecto schema)*
- `lib/engram_web/plugs/require_onboarding.ex` *(new)*
- `lib/engram_web/controllers/onboarding_controller.ex` *(new)*
- `lib/engram_web/router.ex` *(modify — add endpoints, add plug to vault pipeline, whitelist SPA route)*
- `config/runtime.exs` *(modify — add `billing_enabled` and `current_tos_version`)*
- `test/engram/onboarding_test.exs` *(new)*
- `test/engram_web/plugs/require_onboarding_test.exs` *(new)*
- `test/engram_web/controllers/onboarding_controller_test.exs` *(new)*

**Frontend:**

- `frontend/src/onboarding/onboarding-gate.tsx` *(new)*
- `frontend/src/onboarding/onboard-layout.tsx` *(new)*
- `frontend/src/onboarding/onboard-redirect.tsx` *(new)*
- `frontend/src/onboarding/agreement-page.tsx` *(new)*
- `frontend/src/onboarding/onboard-billing-page.tsx` *(new — thin wrapper around existing billing page)*
- `frontend/src/legal/terms-of-service.md` *(new — placeholder body)*
- `frontend/src/api/queries.ts` *(modify — add `useOnboardingStatus`, `useAcceptTerms`)*
- `frontend/src/router.tsx` *(modify — add /onboard routes, wrap protected routes in OnboardingGate)*

**E2E:**

- `e2e/tests/test_onboarding.py` *(new)*
