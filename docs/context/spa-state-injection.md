# Context Doc: SPA State Injection Pattern

_Last verified: 2026-05-30_

## Status
Working. Pattern established in earlier PRs (`authProvider`, `billingEnabled`, etc.); extended in PR #350 with `bootstrap` for self-host first-run UX.

## What This Is
How Engram ships server-known state to the React SPA without a fetch
round-trip — so the first paint can render the correct UI instead of a
default-then-flash. Server-side state that the frontend needs on first
paint goes into a single `<script>window.__ENGRAM_CONFIG__=…</script>` tag
that Phoenix injects into `index.html`. The React bundle reads it
synchronously during module init.

NOT true React SSR. The HTML structure is still empty until React mounts.
This pattern only solves the "I need server state for first-render-correct
UI" problem. For shipping rendered HTML, see issue #353 (future work).

## Environment
Backend: Elixir/Phoenix. Frontend: React 18 + Vite SPA. Pattern works in
both modes:

* **Prod** (Phoenix serves `priv/static/app/index.html`): injection runs;
  config available synchronously on first paint.
* **Dev** (Vite dev server on :5173 serves `index.html` directly): no
  injection; consumers must fall back to a fetch or `import.meta.env`.

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
3. If the injected config is missing (Vite dev), falls back to fetching
   `/config.json`, then to defaults.
4. Exports `export const configPromise = loadConfig()` — a single eager
   `Promise<EngramConfig>` resolved once at module init. Consumers await it
   (e.g. before bootstrapping the React root), not a hook.

**Per-consumer pattern (e.g., `frontend/src/auth/use-bootstrap.ts`):**

```typescript
import { config } from '../config'

let cached: Bootstrap | null | undefined = config.bootstrap
let inflight: Promise<Bootstrap | null> | null = null

export function useBootstrap(): BootstrapState {
  const [state, setState] = useState<BootstrapState>(cached)
  useEffect(() => {
    if (cached !== undefined) return                  // SSR-injected or already fetched
    fetchBootstrap().then(setState)                   // dev fallback
  }, [])
  return state
}
```

The `undefined | null | T` tri-state lets the UI distinguish "still
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

3. **Frontend** — extend the `EngramConfig` interface and
   `loadConfig()` in `frontend/src/config.ts` to include the new field.
   Type it as `T | null | undefined` if it can be absent.

4. **Consumer** — import `config` synchronously where you need it. For
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
  surfaces). See issue #353 for the full SSR architecture discussion.
* **Vite plugin to mirror Phoenix's injection in dev**. Looked at —
  small extra plumbing for the dev-flash trade-off most teams accept.
  Live with the fetch fallback in dev; prod is what users see.

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
  `(pre, post)` around `</head>` in `:persistent_term`. In `:dev`/`:test`
  the cache is disabled (`config :engram, :spa_cache_enabled?, false`),
  so `vite build` rewriting the file with new asset hashes is picked up
  on the next request without a Phoenix restart. The config script
  itself is rebuilt per request — config changes (e.g., flipping
  `AUTH_PROVIDER`) take effect on next page load, no cache to bust.

* **CSP `unsafe-inline`**. Because the config script is inline, the CSP
  in `router.ex` has to allow `script-src 'unsafe-inline'`. TODO: switch
  to a per-request nonce (already noted in `router.ex`).

* **Test cache state**. `SpaControllerTest` clears the
  `:persistent_term` cache in `setup` so each test gets a fresh file
  read. New tests that mutate `Application.put_env` for the config
  should also clear the cache (the cache only covers the HTML split,
  not the config map — but worth knowing if a future test ever caches
  more).

## References

* Backend: `lib/engram_web/controllers/spa_controller.ex`
* Frontend: `frontend/src/config.ts`, `frontend/src/auth/use-bootstrap.ts`
* Tests: `test/engram_web/controllers/spa_controller_test.exs`
* Router (CSP + SPA route whitelist):
  `lib/engram_web/router.ex` around the SpaController routes
* Future SSR architecture discussion: issue #353
* PR that established this doc: #350 (extended pattern with `bootstrap`
  field for self-host first-run UX)
