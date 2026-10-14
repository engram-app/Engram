# Web app frontend dev gotchas: Lighthouse on dev, bun patch + Vite, i18n scanner, CM6 scopes

_Last verified: 2026-10-13_

Six traps hit while doing the mobile/Obsidian polish pass on `frontend/`. Each one cost a debugging loop.

## 1. Lighthouse CLS on the Vite dev server is fake

**Symptom:** a mobile-throttled run (4x CPU, Slow 4G) against `:5173` reports CLS ~0.49-0.51.

**Root cause:** dev-only FOUC. In dev, `main.css` is imported from `src/main.tsx`, so Vite injects it via JS. Until it lands, `index.html`'s static splash (`#root > main` "Loading…") paints unstyled with the UA 8px body margin (body 18.75px tall), then jumps to full screen when CSS arrives. Prod (`app.engram.page`) ships `<link rel="stylesheet">` in `<head>` (render-blocking), so the shift does not happen there.

**Rule:** measure CLS/perf against a production build, never `:5173`. Unthrottled dev CLS is ~0.01, and those residual shifts are DevTools' own panel elements when DevTools is docked.

## 2. Lighthouse "navigation" mode signs you out

Navigation mode clears storage, so it logs the dev user out and audits `/sign-in`. Use **snapshot** mode on an already-authenticated page.

## 3. Lighthouse findings that are noise on app pages

Ignore on app (non-marketing) pages: robots.txt invalid (Vite returns `index.html` for any path), missing meta description, `llms.txt`, "Agentic browsing".

## 4. `bun patch` on a dep: Vite keeps serving the old copy

Applies to `@atomic-editor/editor` (`patches/@atomic-editor%2Feditor@0.6.2.patch`). After `bun patch --commit`, the running Vite still serves the OLD pre-bundled dep from `node_modules/.vite/deps`. Restart Vite with `--force`.

dev-selfhost recipe: kill the PID in `/tmp/saasdev-vite.pid`, then relaunch:

```bash
VITE_AUTH_PROVIDER=local VITE_BILLING_ENABLED=false \
  bun run dev -- --host 0.0.0.0 --port 5173 --strictPort --force
```

The patch currently carries: task-marker source reveal when the caret touches `- [ ] `, and checkbox `aria-label` = task text.

## 5. i18n key scanner only sees literal call shapes

`src/i18n/keys-scan.ts` only recognizes literal `t("...")`, `msg("...")`, `tn({...})`, `<Trans text="...">`.

`state.facet(translator)("Note text")` type-checks but is invisible to the scanner AND to its `HIDDEN_CALL` guard. `bun scripts/i18n-translate.ts` reports 0/0 translated and the key ships untranslated. Bind first:

```ts
const t = state.facet(translator);
t("Note text");
```

Also:

- The translate script needs `I18N_OLLAMA_URL=http://10.0.20.214:11434` on claw (no local Ollama).
- Catalog key ORDER follows source scan order. Moving a `t()`/`msg()` call to another file reorders the catalogs: a diff with no real change.

## 6. `HighlightStyle` scoped to `markdownLanguage` never matches

When the editor uses `markdown({ base: markdownLanguage, extensions: [...] })`, passing `extensions` builds a NEW `Language`. A `HighlightStyle` with `scope: markdownLanguage` then matches nothing. Scope to the returned `md.language` instead:

```ts
const md = markdown({ base: markdownLanguage, extensions: [...] });
HighlightStyle.define(specs, { scope: md.language });
```
