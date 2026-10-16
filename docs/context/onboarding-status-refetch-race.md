# A mutation navigates to a gate-reading page before `["onboarding","status"]` refetches

**Rule.** Any mutation whose caller navigates to a page that reads `gate_ok`
(or any other field of `["onboarding","status"]`) must **await** the status
refetch in `onSuccess`:

```ts
await qc.invalidateQueries({ queryKey: ["onboarding", "status"] });
```

A bare `qc.invalidateQueries(...)` is fire-and-forget: `mutateAsync` resolves,
the caller navigates, and the next page mounts on the stale cached status.
`useAcceptTerms` and `useSetOnboardingProfile` already await; `useCreateVault`
did not.

## Symptom (MCP-first signup)

ChatGPT/Claude signup: OAuth consent -> onboarding wizard -> "Create vault &
continue" -> user lands on `/` (app shell) instead of the consent page's
Approve button. In CI, `frontend/e2e/oauth-consent-onboarding.spec.ts:175`
fails with `element was detached from the DOM` on the Approve button.

## Mechanism

1. `useCreateVault` (`frontend/src/api/queries.ts`) invalidated
   `["onboarding","status"]` without awaiting.
2. `commitFresh` in `onboard-vault-page.tsx` navigates to
   `onboardingDoneTarget()` (the parked consent) as soon as `mutateAsync`
   resolves.
3. Consent (`oauth-authorize-page.tsx`) mounts on the cached `gate_ok: false`
   (fresh users need a vault: `gate_missing` in `lib/engram/onboarding.ex`) and
   bounces to `/onboard`.
4. When the refetch lands, consent's `gate_ok` effect clears the parked
   authorization, so `OnboardRedirect` has nothing to resume and resolves to `/`.

## Why it surfaced now

Latent on main: 45 prior `e2e-browser` runs passed because the refetch usually
won. PR #1992 mounted a locale reporter in `AuthGuard`, an unrelated timing
change that made the stale read lose deterministically. When a timing-only
change breaks a navigation flow, look for an un-awaited invalidate upstream
rather than at the change itself.

## Related trap: AuthGuard is in the eager bundle

`AuthGuard` ships in the eager sign-in bundle. A static import of anything that
pulls react-query or the api client blows the 200 KB initial-JS budget
(`scripts/check-bundle-budget.ts`, run in `verify.yml` after
`build:selfhost`). Mount such components with `lazy()` + `<Suspense>`.

## Debug method that worked

Download the `playwright-artifacts` from the failed run. `error-context.md`'s
page snapshot showed the app shell, not consent, which ruled out a flaky
locator. Then read the `trace.zip` network timeline (status refetch landing
after navigation) and the screencast jpegs (consent flashing, then `/onboard`,
then `/`).

See also `bootstrap-seed-cache-dual-authority.md` (same family: a guard acting
on cache state a mutation already changed server-side).
