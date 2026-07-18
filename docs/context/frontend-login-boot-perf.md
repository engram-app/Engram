# Frontend login boot performance — architecture, measurement, guardrails

_Last verified: 2026-07-02_

Context for anyone touching SPA boot / sign-in latency. Established in PR #842
(2026-07-02), which cut the eager entry from 894 KB (274 KB gz) to 447 KB
(142 KB gz) and removed two round trips from the cold sign-in path.

## The critical path (as designed)

Cold visit to `app.engram.page` while signed out:

1. HTML (edge-cached, Cloudflare Worker static assets) — contains a **static
   splash** inside `#root` (mirrors `src/layout/loading-screen.tsx`; keep the
   two in sync), the theme bootstrap script, inline
   `window.__ENGRAM_CONFIG__`, a `preconnect` to `clerk.engram.page`, and
   `modulepreload` for the `clerk-auth-provider` + `clerk-sign-in` chunks.
2. Render-blocking CSS (~22 KB gz) → splash paints.
3. Eager entry JS (~142 KB gz) downloads **in parallel with** the Clerk
   chunks (modulepreload) while the Clerk TLS handshake warms (preconnect).
4. React mounts; config resolves synchronously (inline, no `/config.json`
   fetch); ClerkProvider loads remote `clerk.browser.js` over the pre-warmed
   connection → sign-in card.

The remote `clerk.browser.js` + FAPI calls are the irreducible tail we don't
control.

## Guardrails (the ways this regresses)

- **`VITE_INLINE_BOOTSTRAP_CONFIG=1` lives in the `build:saas` script**
  (frontend/package.json), NOT in workflow env. It gates the
  `engram-inline-bootstrap` plugin in vite.config.ts (inline config +
  preconnect + modulepreload). It shipped dormant for weeks because the flag
  was documented as "set by build:saas" but nothing set it — prod quietly ran
  the fetch-config + lazy-waterfall path. If you rename/move the build
  entrypoint, carry the flag; `curl -s https://app.engram.page/ | grep
  __ENGRAM_CONFIG__` is the 5-second prod check.
- **Eager-bundle discipline:** route *pages* were lazy but *layouts* were
  not, which dragged yjs+lib0, react-joyride, react-resizable-panels,
  phoenix, @headless-tree, @tanstack/virtual-core and sonner into the bundle
  that gates sign-in. Layouts now resolve through `src/layout/app-shell.ts`
  (one barrel = one async chunk = no nested Suspense fetch waterfall;
  `onboarding/onboard-entry.ts` same pattern). Anything imported by
  `router.tsx`, `main.tsx`, or the auth pages at module scope is on the
  sign-in critical path — check the chunk breakdown before adding imports
  there.
- **Sentry + posthog are dynamic imports.** `sentryReady` resolves to
  `null` on SDK load failure (ad-blockers match "sentry" in URLs); early
  window errors are buffered and flushed into `captureException` at init.
  `RootErrorBoundary` (main.tsx) replaces `Sentry.ErrorBoundary` and uses
  `captureReactException(error, errorInfo)` to keep componentStack. Don't
  reintroduce a top-level `import * as Sentry`.
- **Every lazy chunk needs a failure story.** A deploy rotates hashed asset
  names under open tabs; a lazy render then 404s and lands on React Router's
  default error page (no route defines `errorElement`). The
  `vite:preloadError` listener in main.tsx reloads once (30 s sessionStorage
  guard) to self-heal. Cosmetic chunks (Toaster) additionally sit behind an
  error boundary that renders null. Rarely-shown dialogs (upgrade dialog) are
  warmed via a fire-and-forget `import()` in their provider effect.
- **hljs + KaTeX CSS live in `src/viewer/markdown.css`** (imported by
  note-view, rides the lazy note-page chunk) with `layer(base)` preserved so
  cascade priority vs Tailwind is unchanged. Don't re-import them in
  main.css.

## Selfhost is unaffected by design

`build:selfhost` never sets the inline-bootstrap flag → plugin no-ops →
selfhost keeps window-injection → `/config.json` → defaults, no Clerk tags in
HTML. Everything else (code split, splash, preloadError reload) is
auth-agnostic and benefits selfhost too. Keep saas-only behavior behind the
flag, never in shared code paths.

## How to measure (rolldown/vite 8 gotcha)

`vite build` uses `sourcemap: "hidden"`, and **source-map-explorer chokes on
rolldown maps** ("generated column Infinity"). What works:

```bash
cd frontend
bunx vite build --outDir /tmp/dist --emptyOutDir   # NOT ../priv/static/app — don't clobber the checkout
# per-package bytes inside a chunk: decode the .map VLQ mappings yourself —
# tally (segment start → next segment start) per source, group by
# node_modules package. ~40 lines of python; see PR #842 discussion.
# quick containment check (is package X in chunk Y):
grep -c "node_modules/yjs" /tmp/dist/assets/index-*.js.map
```

The maps survive in a custom `--outDir` because the strip-sourcemaps plugin
only cleans the default `../priv/static/app` output.

## Related

- PR #842 (perf wave + review hardening), PR #841-era chunk history in
  router.tsx comments
- e2e flakes surfaced during the merge: #843 (SPA CRDT interleave assertion),
  #844 (plugin CRDT propagation timeout) — both contention-window flakes
