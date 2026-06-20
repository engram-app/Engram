# Context Doc: Frontend Login Load Optimization (saas build)

_Last verified: 2026-06-20_

## Status
Shipped in PR #673 (branch `perf/login-cf-optim`).

## What This Is
How the saas build front-loads the login critical path so the Clerk sign-in
widget paints fast instead of after a serial waterfall. Self-host is untouched.

## Environment
`frontend/` React SPA (Vite — actually **rolldown-vite**, note the
`rolldown-runtime` chunk). saas changes are gated behind
`VITE_INLINE_BOOTSTRAP_CONFIG=1` (set in `package.json` `build:saas`).

## Root Cause (the slowness)
Serial critical-path waterfall on the saas build:
parse main bundle → block on a `no-cache` fetch of `/config.json` → mount
`ClerkProvider` → lazy-load the sign-in chunk → only then Clerk's network
bootstrap. Nothing warmed Clerk's connection early, so the page sat blank for
several seconds.

## The Fix (PR #673) — 5 saas-only changes
All gated on `VITE_INLINE_BOOTSTRAP_CONFIG=1`; the selfhost SSR/fetch config
path is byte-for-byte unchanged.

1. **preconnect + dns-prefetch** to `clerk.engram.page` injected into
   `index.html` — TLS handshake to Clerk FAPI happens during bundle parse.
2. **Inline `window.__ENGRAM_CONFIG__` at build** — `loadConfig()` checks it
   first and resolves synchronously (no `/config.json` RTT). `config.json` is
   still emitted as a fallback.
3. **modulepreload** the `clerk-auth-provider` + `clerk-sign-in` chunks so they
   download in parallel with the main bundle (not in a lazy waterfall).
4. **Defer `posthog-js`** via dynamic import in `src/main.tsx` — keeps it out of
   the eager bundle that gates first paint; `identify` still happens later in the
   Clerk auth provider.
5. **Cache-Control in `frontend/public/_headers`** — hashed `/assets` immutable
   for 1y; `index.html` + `config.json` `no-cache` so deploys propagate.

The env→config mapping is consolidated in **`frontend/scripts/bootstrap-config.ts`**
(single source of truth), reused by both `write-config-json.ts` and the
`inlineBootstrap()` Vite plugin in `vite.config.ts`. Has unit tests
(`bootstrap-config.test.ts`).

## THE KEY GOTCHA — rolldown manualChunks pulls Clerk eager
A custom `manualChunks` that split BOTH a `react` vendor chunk AND a `clerk`
vendor chunk caused **rolldown** to merge `react` INTO the clerk-named chunk
(both are shared by the eager entry). Because the eager entry needs react, the
whole ~322KB "clerk" chunk then became a **static import of the entry** —
promoting the Clerk SDK to EAGER. It showed up in Vite's auto-modulepreload
block and `index.js` did `import {...} from "./clerk-XXXX.js"`. That is a
regression: Clerk must stay lazy.

**Lesson:** when a forced vendor chunk statically imports a module the eager
entry also needs, rolldown can place the shared module in the named chunk and
pull the whole chunk eager.

**Resolution: dropped custom `manualChunks` entirely.** rolldown defaults
already keep Clerk lazy (inside `clerk-auth-provider` / `clerk-sign-in` chunks);
explicit modulepreload of those chunks parallelizes the load WITHOUT making them
eager.

## How To Verify The saas Build
After `bun run build:saas` with the saas `VITE_*` env + `VITE_INLINE_BOOTSTRAP_CONFIG=1`:

- `grep` `dist/index.html` for: `preconnect` (clerk.engram.page),
  `__ENGRAM_CONFIG__`, and the two clerk `modulepreload` links.
- Confirm the entry `index-*.js` does **NOT** statically `import` a clerk chunk
  (Clerk must stay lazy). If `index-*.js` has `import ... from "./clerk-*.js"`,
  the manualChunks regression is back.
- Confirm `posthog` is **not** in the main `index-*.js` chunk.

## 14KB-First-Trip Note
A ~795KB client-rendered SPA can't paint within the 14KB first-RTT window
without SSR. The achievable target is `index.html` (the first-RTT response),
which now carries all the resource hints (preconnect, inline config,
modulepreloads). An inline static loading skeleton was discussed as a future
FCP win but **deferred**.

## References
- PR #673 / branch `perf/login-cf-optim`
- `frontend/index.html`, `frontend/public/_headers`, `frontend/vite.config.ts`
- `frontend/src/main.tsx`
- `frontend/scripts/bootstrap-config.ts`, `frontend/scripts/write-config-json.ts`
- `frontend/package.json` (`build:saas`)
- Related: `docs/context/frontend-architecture.md`, `docs/context/spa-state-injection.md`
