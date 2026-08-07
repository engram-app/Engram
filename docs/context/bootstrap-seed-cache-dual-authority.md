# Context Doc: Bootstrap Seed Cache — Dual-Authority Bug Class

_Last verified: 2026-08-06_

## Status
Working — architecture rule documented after PR #1299 fixed the third instance of this bug class.

## What This Is
The SPA's `useAppBootstrap` (`frontend/src/api/queries.ts`) fetches `GET /bootstrap` once (`staleTime: Infinity`, key `["bootstrap"]`) and **seeds** the granular caches via `qc.setQueryData`: `["onboarding","status"]`, `["capabilities"]`, `["vaults"]`, and `["billing","status"]` (when billing is enabled). The architecture rule: **bootstrap is a fetch-and-seed vehicle; the granular keys are the only readable source of truth.** Nothing may route or render off the bootstrap payload's own copy of a slice.

## The Bug (fixed in PR #1299)
`OnboardingGate` (`frontend/src/onboarding/onboarding-gate.tsx`) routed off `data.onboarding` from the bootstrap payload. Wizard mutations (`useAcceptTerms`, `useSetOnboardingProfile`, `useCreateVault`) invalidate only `["onboarding","status"]` — the bootstrap copy stayed frozen forever. A user completing the wizard got bounced back to `/onboard/agreement` in a redirect loop: the fresh granular status said "done" at `/onboard`, the stale bootstrap copy said "agreement" at `/`. Only a full page reload escaped. Hit a real paying user mid-onboarding on 2026-08-06.

Fix: the gate now reads `useOnboardingStatus({ enabled: data !== undefined })` — the granular key every wizard mutation invalidates — with `enabled` gating on the bootstrap seed so first load stays one request.

## Prior Instances (same class)
- **Capabilities/tier stuck after upgrade (#603)** — see the `invalidateBillingState` comment in `queries.ts`.
- **Vault-count staleness** — `useDeleteVault` / `useRestoreVault` / `usePurgeVault` invalidate `["bootstrap"]` because vault deletion changes onboarding `next_step` server-side; the refetch re-seeds all granular keys.

## Rules Going Forward
1. **Read via the granular hooks** (`useOnboardingStatus`, `useCapabilities`, ...) — never `bootstrap.data.<slice>`.
2. A mutation that changes a seeded slice **invalidates the granular key** — that is sufficient for any reader.
3. Invalidating `["bootstrap"]` is only needed when the server recomputes a slice as a **side effect the client can't name** (e.g. vault deletion changing `next_step`) — its refetch re-seeds everything.
4. A consumer that must mount alongside the gate before the seed lands should use `useOnboardingStatus({ enabled })` to avoid racing bootstrap with a duplicate fetch.

## Gotchas / Debug Tell
"Works after a hard refresh, but loops or goes stale within the SPA session" = a reader is on a never-invalidated cache copy. Find who reads the stale slice and move them to the granular key; don't add more `["bootstrap"]` invalidations.

## References
- `frontend/src/api/queries.ts` — `useAppBootstrap`, `useOnboardingStatus`, `invalidateBillingState`, vault lifecycle mutations
- `frontend/src/onboarding/onboarding-gate.tsx`
- PR #1299 (gate fix), #603 (tier staleness)
