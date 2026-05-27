# Custom Account Page — Design

**Date:** 2026-05-27
**Repo:** engram-app/engram (`frontend/`)
**Branch:** `feat/unified-settings-page` (or a follow-up branch)
**Status:** Spec — implementation to run in a fresh session via `writing-plans`.

## Problem

Settings → Account currently embeds Clerk's prebuilt `<UserProfile>` (see
`frontend/src/settings/account-page.tsx`). On mobile this is unusable: Clerk's
component has its own internal navigation that collapses into its own hamburger,
which sits inside our settings panel that already has a section-drawer hamburger
— two stacked hamburgers, and Clerk's UI crammed into a narrow pane. It also
"forces its own style" despite token theming.

## Goal

Replace the embedded `<UserProfile>` with a **fully custom, responsive account
UI** assembled from Clerk hooks + `User` object methods, at **full feature
parity**. One layout for mobile and desktop: a single vertical scroll of
independent **section cards**. This structurally removes the nested-navigation
problem (no inner nav, no second hamburger) and gives full control of styling
via our design tokens.

## Decisions

- **Approach:** custom UI (not `<UserProfile>`). Clerk officially supports this
  via documented "custom flows → account-updates" guides; we assemble ~7
  per-action flows into one page. We own maintenance — new Clerk features will
  not appear automatically.
- **Reverification:** use `useReverification()`'s **built-in** prompt (Clerk
  renders its own small re-auth modal when a sensitive action needs fresh
  auth). We do not build a custom re-auth challenge.
- **Layout:** single scrolling stack of section cards; identical on mobile and
  desktop (the settings content pane is already full-bleed on mobile). No inner
  tabs.
- **Feature scope:** full parity — profile, email, password, MFA (TOTP +
  backup codes), connected accounts, active sessions, delete account.
- **Config-gating:** each section/field renders only when the Clerk instance
  enables it (password auth, specific OAuth providers, MFA factors, phone).
  Degrade gracefully — never show a control the instance can't satisfy.

## Architecture

`account-page.tsx` becomes a thin composition: a heading + a vertical stack of
section components, each wrapped in a shared `SettingsSectionCard`. Each section
is **independent** — it reads its own slice of `useUser()`, owns its mutations,
and manages its own loading/error/toast state. No section depends on another.

### Shared primitives

- `SettingsSectionCard` (`frontend/src/settings/account/section-card.tsx`) —
  presentational wrapper: `<section>` with a token-styled card, a header
  (title + optional description), and a body slot. Reused by every section for
  visual consistency.
- All sensitive mutations are wrapped with `useReverification()` so Clerk's
  re-auth prompt fires automatically when required.
- Success → sonner toast (existing `Toaster`). Errors → `ClerkAPIResponseError`
  is caught; `.errors[]` mapped to field- or form-level messages.

### Sections (one file each, under `frontend/src/settings/account/`)

| Section | File | Key Clerk APIs |
|---|---|---|
| Profile | `profile-section.tsx` | `useUser()`, `user.update({ firstName, lastName })`, `user.setProfileImage({ file })` |
| Email addresses | `email-section.tsx` | `user.emailAddresses`, `user.createEmailAddress({ email })`, `emailAddress.prepareVerification({ strategy: 'email_code' })`, `emailAddress.attemptVerification({ code })`, `user.update({ primaryEmailAddressId })`, `emailAddress.destroy()` |
| Password | `password-section.tsx` | `user.updatePassword({ currentPassword, newPassword, signOutOfOtherSessions })`; `user.passwordEnabled` to choose set-vs-change |
| Two-factor (MFA) | `mfa-section.tsx` | `user.createTOTP()` → render QR from `totp.uri` → `user.verifyTOTP({ code })`; `user.createBackupCode()`; `user.disableTOTP()`; `user.twoFactorEnabled` |
| Connected accounts | `connected-accounts-section.tsx` | `user.externalAccounts`, `user.createExternalAccount({ strategy, redirectUrl })` (OAuth redirect), `externalAccount.destroy()` |
| Active sessions | `sessions-section.tsx` | `useSessionList()` (or `user.getSessions()`), `session.revoke()`, compare against active `useSession()` to mark current |
| Danger zone | `danger-zone-section.tsx` | `user.delete()` behind a typed confirmation ("delete my account") |

`account-page.tsx` renders the heading then the sections in order, each gated by
config:
- Password section only if password auth is enabled.
- Connected accounts only for OAuth providers the instance configures (derive
  the available strategies from Clerk's environment / `user.externalAccounts`
  plus enabled providers).
- MFA only if at least one second factor is enabled; SMS sub-option only if
  phone is enabled.
- Phone section is **out of scope** unless the instance enables phone identifiers
  (then add `phone-section.tsx` mirroring the email flow).

### Data flow

`useUser()` exposes a reactive `user` resource; Clerk updates it after
mutations, so sections re-render without manual cache wiring. Where a mutation
returns a new sub-resource (e.g. a freshly created email needing verification),
hold it in local component state for the verification step, then rely on the
reactive `user.emailAddresses` afterward. Call `user.reload()` only if a flow
leaves the resource stale.

## Reverification details

`useReverification(fn)` returns a wrapped callable; when Clerk's backend returns
a "needs reverification" response, the hook surfaces Clerk's built-in modal,
and on success re-invokes `fn`. Wrap: password update, email removal/primary
change, MFA enable/disable, connected-account unlink, and account deletion.
Handle user-cancelled reverification (no-op + dismiss any pending UI).

## Error handling

- Import `isClerkAPIResponseError` / catch `ClerkAPIResponseError`; read
  `err.errors[].{code,message,meta.paramName}`.
- Map `paramName` to the offending field where present; otherwise show a
  form-level error line (token `text-destructive`).
- Network/unknown → generic "Something went wrong, try again" + toast.

## Layout & styling

- Single column inside the existing settings content pane (`min-w-0 flex-1
  overflow-y-auto p-4 sm:p-6`). Cards `space-y-6`.
- Everything uses design tokens (`foreground`, `muted-foreground`, `border`,
  `input`, `card`, `muted`, `primary`, `destructive`) — no hardcoded
  gray/blue/red. Danger zone uses `destructive` tokens.
- Forms reuse existing shadcn/ui primitives (`Button`, inputs) and the patterns
  already in `api-keys-page.tsx`.
- Mobile: no special-casing needed — the stack is inherently responsive; the
  settings pane is already full-bleed on mobile.

## Testing

- Per-section unit tests (Vitest + RTL) with Clerk hooks mocked
  (`vi.mock('@clerk/clerk-react')` for `useUser`, `useReverification`,
  `useSessionList`, `useSession`). Assert:
  - Profile: `user.update` called with edited name; avatar calls
    `setProfileImage`.
  - Email: add triggers `createEmailAddress` → `prepareVerification`; entering a
    code triggers `attemptVerification`; remove triggers `destroy`.
  - Password: `updatePassword` called with the right args; set-vs-change branch
    keys off `passwordEnabled`.
  - MFA: enable path calls `createTOTP` then `verifyTOTP`; disable calls
    `disableTOTP`; rendering gated by `twoFactorEnabled` + instance config.
  - Sessions: lists from `useSessionList`, revoke calls `session.revoke`,
    current session not revocable.
  - Danger zone: delete disabled until the confirmation phrase matches.
  - Config-gating: sections hidden when the corresponding capability is off.
- Reverification wrapper tested by asserting the mutation is invoked through the
  `useReverification`-wrapped callable (mock passes through).
- OAuth link and live TOTP/SMS flows involve redirects/external apps → **manual
  smoke** (note in plan), not unit-tested.

## File structure

```
frontend/src/settings/
  account-page.tsx                     # composition: heading + gated section stack
  account/
    section-card.tsx                   # shared card wrapper
    profile-section.tsx
    email-section.tsx
    password-section.tsx
    mfa-section.tsx
    connected-accounts-section.tsx
    sessions-section.tsx
    danger-zone-section.tsx
    *.test.tsx                         # per-section
```

This removes the current `appearance`-style single-file `account-page.tsx`
(Clerk `<UserProfile>` embed) — delete that body and the `appearance` override.

## Reference implementations (Clerk docs — copy-ready per section)

No single OSS repo replaces `<UserProfile>`; Clerk's per-action custom-flow
guides are the canonical source (each includes complete React code):

- Add/verify email: `https://clerk.com/docs/guides/development/custom-flows/account-updates/add-email`
- Update password: `https://clerk.com/docs/guides/development/custom-flows/account-updates/update-password`
- Manage MFA (TOTP + backup codes): `https://clerk.com/docs/guides/development/custom-flows/account-updates/manage-mfa`
- Manage SSO/connected accounts: `https://clerk.com/docs/guides/development/custom-flows/account-updates/manage-sso-connections`
- Reverification: `https://clerk.com/docs/guides/secure/reverification` and `https://clerk.com/docs/react/reference/hooks/use-reverification`
- Object refs: `https://clerk.com/docs/react/reference/objects/user`, `https://clerk.com/docs/react/reference/types/email-address`, `https://clerk.com/docs/react/reference/objects/session`

The build session should fetch these (e.g. `firecrawl_scrape` to markdown) for
exact, current code per section.

## Out of scope

- Passkeys, web3 wallets, organizations/teams.
- Phone/SMS unless the Clerk instance enables phone identifiers (add a mirrored
  `phone-section.tsx` if so).
- Any backend change — this is purely the frontend account UI; Clerk owns the
  data.

## Build handoff

Implementation runs in a fresh session: start from this spec, run
`superpowers:writing-plans` to produce a task-by-task plan (one section per
task is a natural unit), then execute (subagent-driven). The current
`feat/unified-settings-page` branch already carries the unified settings page +
mobile/tokenization work this builds on.
