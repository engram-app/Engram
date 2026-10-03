# Context Doc: SPA State Injection Pattern

_Last verified: 2026-10-03_

## Status
Working. Self-host: Phoenix injects per request. Saas: the same global is inlined
into `index.html` at build time (see "Saas" below).

## What This Is
How Engram ships server-known state to the React SPA without a fetch
round-trip — so the first paint can render the correct UI instead of a
default-then-flash. Server-side state that the frontend needs on first
paint goes into a single `<script>window.__ENGRAM_CONFIG__=…</script>` tag
that Phoenix injects into `index.html`. The React bundle reads it
synchronously during module init.

NOT true React SSR. The HTML structure is still empty until React mounts.
This pattern only solves the "I need server state for first-render-correct
UI" problem.

## Environment
Backend: Elixir/Phoenix. Frontend: React 19 + Vite SPA. Pattern works in
these modes:

* **Prod** (Phoenix serves `priv/static/app/index.html`): injection runs;
  config available synchronously on first paint.
* **Dev** (Vite dev server on :5173 serves `index.html` directly): no
  injection; consumers must fall back to a fetch or `import.meta.env`.
* **Saas** (Cloudflare Worker serves `frontend/dist`, no Phoenix shell):
  `build:saas` sets `VITE_INLINE_BOOTSTRAP_CONFIG=1`, and the
  `engram-inline-bootstrap` plugin in `vite.config.ts` inlines
  `window.__ENGRAM_CONFIG__` from `scripts/bootstrap-config.ts`. The same
  mapping writes `dist/config.json` as a fallback.

## How It Works

**Backend (`lib/engram_web/controllers/spa_controller.ex`):**

1. Reads `priv/static/app/index.html`, splits on `</head>`, caches the
   split in `:persistent_term` (cache disabled in `:dev`/`:test`).
2. Builds a Map of values to inject. Currently:
   ```elixir
   %{
     authProvider: provider,            # "local" | "clerk"
     clerkPublishableKey: ...,
     billingEnabled: ...,
     bootstrap: ...                     # self-host only; nil under Clerk
   }
   ```
3. JSON-encodes with `</` and `<!--` escape so the JSON can never close
   the `<script>` tag or open an HTML comment.
4. Wraps in `<script>window.__ENGRAM_CONFIG__=…;</script>` and inserts
   immediately before `</head>`.

**Frontend (`frontend/src/config.ts`):**

1. `loadConfig()` (async) reads `window.__ENGRAM_CONFIG__` at module init time.
2. Validates `authProvider`. Returns a typed `EngramConfig`.
3. If the injected config is missing, falls back to fetching
   `/config.json`, then to `VITE_*` defaults.
4. Exports `export const configPromise = loadConfig()` — a single eager
   `Promise<EngramConfig>` resolved once at module init. Consumers await it
   (e.g. before bootstrapping the React root), not a hook.

**Per-consumer pattern (`frontend/src/auth/use-bootstrap.ts`):** a
module-level `cached` seeded from `ConfigContext`'s `bootstrap` on first hook
call, plus one shared in-flight `fetch` of `/api/auth/bootstrap` when the seed
is `undefined` (not injected). The `undefined | null | T` tri-state lets the UI distinguish "still
loading" (render a placeholder) from "definitively no data" (Clerk / 404 /
error → use defaults).

## Adding a New Injected Value — Recipe

1. **Decide it qualifies.** Only inject state that is:
   * Known to the server at request time
   * Stable enough that "stale for the duration of this page render" is
     acceptable (no real-time data)
   * Public / non-sensitive (it's in the HTML response body — assume
     attacker-readable)
   * Small (each injection bloats every HTML response)

2. **Backend** — add a field to the `config` map in
   `SpaController.config_script/0`. Read from `Application.get_env/3` or
   compute from a context fn. Self-host-only fields gate on
   `provider == "local"` and return `nil` under Clerk.

3. **Frontend**, extend the `EngramConfig` interface and `normalize()` /
   `defaultConfig()` in `frontend/src/config.ts`. Type it as
   `T | null | undefined` if it can be absent.

   **Saas too:** add the field to `BootstrapConfig` in
   `frontend/scripts/bootstrap-config.ts`, or saas never receives it and
   `normalize()` silently falls back to the default. (`tracingEnabled` is in
   neither `SpaController` nor `bootstrap-config.ts` today, so it is false
   everywhere.)

4. **Consumer**, read it via `useConfig()`; non-React code uses a module
   singleton set in `BootstrapGate` (as `getApiBase()` does). For
   tri-state fields that the UI must wait on, use a `useBootstrap`-style
   hook with cache + dev fetch fallback.

5. **Tests** — add an assertion in
   `test/engram_web/controllers/spa_controller_test.exs` that the field
   ships in the rendered HTML. Test both `:local` and `:clerk` paths if
   the value differs.

6. **Public fallback endpoint** (if the field needs to work in dev): keep
   the existing `/api/auth/bootstrap`-style endpoint as the dev fetch
   target AND a version-skew safety net for when a new SPA bundle ships
   against an older Phoenix that didn't yet inject the field.

## What This Pattern Is NOT For

* **Per-user data** (vault list, current note, user preferences). It's
  injected at request time without auth — anyone hitting the SPA shell
  gets the same value.
* **Real-time / push-updated data**. The config is frozen at HTML render
  time. Use Phoenix Channels for live data.
* **Sensitive credentials**. Anything in the script tag is plaintext in
  the response body.
* **Large blobs**. Bloats every HTML response. Threshold is fuzzy —
  small JSON objects (<1KB) are fine.

## Failed Approaches / Dead Ends

* **Two separate injection points** (one for auth config, one for
  bootstrap). Considered then rejected — piggybacking on the existing
  `__ENGRAM_CONFIG__` script tag means one source of truth and one
  place to extend.
* **localStorage cache across sessions**. Considered for cold-load UX —
  rejected because (a) the first-ever visit still has the problem,
  (b) staleness across browser sessions is a real bug class, and
  (c) the SSR injection already solves it for prod.
* **Node sidecar for full React `renderToString`**. Explored, rejected.
  Operational nightmare (two runtimes, IPC, pool management, error
  surfaces). Issue #353 (closed).

## Gotchas

* **Module script execution order**. The bundle is loaded via
  `<script type="module" src="…">`. Module scripts are deferred —
  they execute after HTML parsing finishes. The inline `__ENGRAM_CONFIG__`
  script (synchronous) is therefore evaluated BEFORE the module runs,
  even if the module's `<script>` tag appears earlier in source order.
  This is why reading the config at module-init time in `config.ts`
  works reliably.

* **JSON escaping**. Always escape `</` to `<\/` and `<!--` to `<\!--`
  in the embedded JSON. Otherwise an attacker-controllable string in
  the injected payload (an admin display name, a vault label) could
  close the `<script>` tag or open an HTML comment and break out.
  `SpaController.config_script/0` already does this.

* **Vite dev server doesn't inject**. If you're seeing a default→correct
  flash in dev, check the URL bar — `:5173` is Vite (no injection,
  fetch fallback). `:4000` is Phoenix (injection, no flash). Both
  forward to the same backend.

* **Cache invalidation in dev**. `SpaController` caches the split
  `(pre, post)` around `</head>` in `:persistent_term`. In `:dev` the
  cache is disabled (`config :engram, :spa_cache_enabled?, false` in
  `config/dev.exs`; `SpaControllerTest` erases the term in `setup`
  instead), so `vite build` rewriting the file with new asset hashes is picked up
  on the next request without a Phoenix restart. The config script
  itself is rebuilt per request — config changes (e.g., flipping
  `AUTH_PROVIDER`) take effect on next page load, no cache to bust.

* **CSP `unsafe-inline`**. Because the config script is inline, the CSP
  in `lib/engram_web/csp.ex` has to allow `script-src 'unsafe-inline'`. TODO: switch
  to a per-request nonce (already noted in `router.ex`).

## References

* Backend: `lib/engram_web/controllers/spa_controller.ex`
* Frontend: `frontend/src/config.ts`, `frontend/src/auth/use-bootstrap.ts`
* Tests: `test/engram_web/controllers/spa_controller_test.exs`
* Router (CSP + SPA route whitelist):
  `lib/engram_web/router.ex` around the SpaController routes
* Saas inlining: `frontend/vite.config.ts` (`inlineBootstrap`),
  `frontend/scripts/bootstrap-config.ts`
