# Context Doc: Lighthouse mobile CLS from an empty-opened note doc

_Last verified: 2026-10-14_

## Status
Fixed in PR #1978 (shipped 0.51.1). Mobile CLS 0.146 -> 0.000.

## What This Is
Why `frontend/e2e/lighthouse.spec.ts` scored mobile CLS 0.146 on some runs and
0.000 on others for the same code, how the shift was pinned down, and the rule
that keeps it fixed.

## Symptom
The release e2e gate (`release-e2e-gate` in `.github/workflows/deploy-prod.yml`)
refused 0.51.0: the Lighthouse spec reported mobile CLS 0.146 > 0.1. Other runs
of the SAME code scored 0.000. The result was bimodal, not noisy: either the full
shift happened or none did. A bimodal score points at a race, not at layout jitter.

## Root Cause
A note with no local IndexedDB copy opens on an EMPTY Y.Doc. `openDoc` resolves
before the handshake finishes; the server's `step1:reply` is what delivers the
text and the frontmatter.

1. The page painted a blank editor right under the note title.
2. When the reply landed, the `PropertiesWidget` appeared above the editor and
   pushed `.cm-scroller` from y=108 to y=267. That is the 0.146.
3. The spec's `beforeAll` opens the note in a setup tab and closes it as soon
   as `.cm-content` is visible. If that happened before the reply landed,
   IndexedDB stayed empty, so the audited load opened on an empty doc again and
   replayed the shift. If the reply landed first, IndexedDB held the content,
   the audited load painted it at once, and CLS was 0.000. Hence bimodal.

## Fix
`frontend/src/viewer/use-doc-ready.ts` holds the "Connecting…" placeholder until
the doc holds content, unless REST says the note is genuinely empty (an empty
note must still open its editor straight away).

**Rule:** never paint the editor over an empty-opened doc for a note the server
says has content. Anything that renders above the editor (properties, banners)
arrives with the content, so painting early guarantees a shift.

## Method That Found It
Get the shifted rects BEFORE theorizing.

- Run Lighthouse's Node API from a throwaway Playwright spec, then read
  `result.artifacts.Trace.traceEvents` filtered to `name === "LayoutShift"`.
  Each event's `args.data.impacted_nodes[].old_rect` / `new_rect` gives the
  exact before/after position of every moved node.
- The lhr `layout-shifts` audit only names the node, not where it moved from
  or to. It is not enough to find the cause.

## Failed Approaches / Dead Ends
- **PropertiesWidget render timing** (PR #1978 first commit, reverted). Theory:
  the widget re-rendered a task after CodeMirror via `useState`. Switching to
  `useSyncExternalStore` changed nothing (still 0.146). The theory was built
  from the node name alone, before anyone looked at the rects.
- **PerformanceObserver in a plain Playwright mobile context.** No shift was
  observed at all. Lighthouse reproduced it 3/3. Use Lighthouse itself for the
  repro, not a hand-rolled observer.

## Local Repro Recipe
1. Throwaway Postgres 18 (uuidv7 needs pg18): `pgvector/pgvector:pg18` on port
   55432.
2. `mix ecto.setup` with `DATABASE_URL` pointed at it.
3. In `frontend/`: `bunx vite build --mode selfhost`.
4. Run the spec:
   ```bash
   CI=true RATE_LIMIT_AUTH_OVERRIDE=1000 PRE_AUTH_RATE_LIMIT_OVERRIDE=100000 \
     ENGRAM_DEFAULT_REGISTRATION_MODE=open JWT_SECRET=... \
     bunx playwright test --project lighthouse
   ```

## Gotchas
- Without `CI=true` the rate-limit overrides are ignored and many local specs
  fail with 429.
- A cached local IndexedDB copy hides the bug. Any repro must open the note on
  a cold profile (or with the setup tab closed before the handshake reply).

## References
- `frontend/e2e/lighthouse.spec.ts`
- `frontend/src/viewer/use-doc-ready.ts`
- `.github/workflows/deploy-prod.yml` (`release-e2e-gate`)
- PR #1978
