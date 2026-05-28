# Unified Settings Page — Design

**Date:** 2026-05-27
**Repo:** engram-app/engram (`frontend/`)
**Branch:** `feat/unified-settings-page`

## Problem

Settings and user-management surfaces are scattered:

- Settings renders *inside* `AppLayout`, so it inherits the vault chrome (folder
  tree + resizable right panel) — it behaves like a panel in the vault flow, not
  a dedicated page.
- Billing exists in **two** places: the real UI is `BillingPage` at `/billing`
  (also a header nav link), while `/settings/billing` is a dead
  `BillingPlaceholder` that just links back to `/billing`.
- Account management lives in Clerk's own modal, opened by the top-right
  `UserButton` — a separate flow disconnected from Settings.

## Goal

One Settings page that owns every per-user configuration surface (account,
appearance, API keys, encryption, billing), rendered below the app header at
full width, with a single canonical billing location and Clerk account
management folded in.

## Decisions (from brainstorming)

1. **Layout (Q1=B):** Settings keeps the top header bar but drops the folder
   tree and resizable panels — full-width content below the header.
2. **Billing (Q2/Q4=A):** Move the real `BillingPage` content into Settings as
   the Billing section. Delete the standalone `/billing` route and its header
   nav link. One billing, under Settings.
3. **Account (Q3=A):** Embed Clerk `<UserProfile />` as an **Account** section
   inside Settings. Local-auth mode omits the Account entry/route entirely.
4. **Header avatar (Q4=A):** Keep Clerk `UserButton`, configured
   `userProfileMode="navigation"` + `userProfileUrl="/settings/account"`, so
   "Manage account" navigates into Settings instead of opening the modal.

Section order: **Account, Appearance, API Keys, Encryption, Billing**.

## Architecture

### Shared header extraction

The header markup (Engram logo + main nav + `ThemeToggle` + `UserButton`/
`LocalUserMenu`) is currently duplicated in `DesktopLayout` and `MobileLayout`
inside `app-layout.tsx`. Extract it into a single `AppHeader` component so both
the vault layout and the new settings layout render an identical header (and the
`UserButton` navigation config lives in one place).

`AppHeader` responsibilities:
- Logo link to `/`.
- Main nav: **Search**, **Settings** (Billing link removed).
- `ThemeToggle`.
- Auth control: Clerk `UserButton` (with `userProfileMode="navigation"` +
  `userProfileUrl="/settings/account"`) or `LocalUserMenu`, lazy-split on
  `config.authProvider` exactly as today.

Mobile retains its left drawer trigger; that stays in `MobileLayout` and is not
part of `AppHeader` (the drawer is vault-specific). `AppHeader` covers the
shared logo+nav+actions cluster on the right.

### Layouts

- `AppLayout` (vault): `AppHeader` + folder tree + resizable panels. Behavior
  unchanged apart from sourcing the header from `AppHeader` and dropping the
  Billing nav link.
- `SettingsLayout` (new): `AppHeader` + a centered content region containing the
  settings nav rail (existing `settings-layout.tsx` markup) and the routed
  `Outlet`. No folder tree, no right panel, no `RightSidebarProvider`,
  no `useChannel`.

### Router changes (`router.tsx`)

Move the `/settings` subtree out from under `AppLayout` and under
`SettingsLayout`, still nested inside `AuthGuard` → `OnboardingGate`. Delete the
standalone `/billing` route.

```
AuthGuard
 └─ OnboardingGate
     ├─ AppLayout
     │   ├─ /            Dashboard
     │   ├─ /note/*      NotePage
     │   └─ /search      SearchPage
     ├─ SettingsLayout
     │   └─ /settings
     │       ├─ index           → redirect to "account" (clerk) / "appearance" (local)
     │       ├─ account         AccountPage        (clerk only)
     │       ├─ appearance      AppearancePage
     │       ├─ api-keys        ApiKeysPage
     │       ├─ encryption      EncryptionPage
     │       └─ billing         BillingPage
     ├─ /device-link   DeviceLinkPage
     └─ /oauth/...     OAuthAuthorizePage
```

`DeviceLinkPage` and `OAuthAuthorizePage` keep their current placement under
`OnboardingGate`.

### Account section

New `settings/account-page.tsx`:
- Clerk mode: render `<UserProfile routing="path" path="/settings/account" />`.
  `routing="path"` is required so Clerk's internal sub-navigation (security,
  sessions, connected accounts) maps onto nested URL segments rather than the
  default hash routing. The `/settings/account` route therefore needs a wildcard
  (`account/*`) so Clerk's own sub-routes resolve.
- Local-auth mode: the Account nav entry and route are not registered at all
  (config-gated, mirroring the existing `isClerk` split). No placeholder.

### Settings nav (`settings-layout.tsx`)

The `SECTIONS` list becomes config-aware: prepend `Account` only when
`config.authProvider === 'clerk'`. Billing stays in the list (now pointing at
the folded-in billing section). Existing NavLink styling unchanged.

### Billing fold-in

- `/settings/billing` renders the existing `BillingPage` component. It already
  accepts `hideHeading` and is width-constrained (`max-w-2xl`), so it slots into
  the settings content region directly. Decide heading handling: the settings
  section provides its own context, so render `BillingPage` with its default
  heading (it is the section's primary content) — no behavioral change needed
  beyond the route move.
- Update `BillingPage`'s checkout `successUrl` from `/billing?status=success` to
  `/settings/billing?status=success`.
- Delete `settings/billing-placeholder.tsx`.
- `onboarding/onboard-billing-page.tsx` continues to import and use `BillingPage`
  (with `hideHeading`) unchanged.

## Out of scope

- Plan card pricing is stale (`$5/$10` vs pricing-v2 `$10/$20`) — not touched
  here; tracked separately.
- No redesign of individual section internals (appearance/api-keys/encryption
  panels keep their current markup).
- No change to onboarding flow.

## Testing

### Automated (Vitest + RTL)

- `SettingsLayout` renders the shared header and the settings nav rail.
- `/settings` index redirects to the first section (account under clerk,
  appearance under local).
- Account nav entry + route present under clerk config, absent under local
  config.
- `AppHeader` renders Search + Settings nav and omits a Billing link.
- Router smoke: `/billing` is no longer a registered route (resolves to
  not-found / no standalone billing page).

### Manual (laptop Chrome over SSH tunnel, chrome-devtools MCP)

- Each settings section loads at full width below the header; no folder tree or
  right panel present.
- Billing section: plan checkout opens, "Manage subscription" portal works,
  `successUrl` returns to `/settings/billing`.
- Top-right avatar → "Manage account" navigates to `/settings/account` (no Clerk
  modal); Clerk sub-tabs (security/sessions) work via path routing.
- Mobile layout: drawer + nav unaffected; Settings reachable; no Billing link.
- Vault view regression check: folder tree, right panel, search all unchanged.
