# Note Links Frontend Rewire Implementation Plan (refs #592)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consume the note_links backend — wikilinks render direct `/:slug/:uuid` hrefs from the note payload's `links`, a backlinks panel in the right rail, and `[[` autocomplete in the editor.

**Architecture:** NotePage builds a target→edge map from `note.links`; `wikiHref` gains a map-aware variant that emits direct UUID hrefs for resolved targets and falls back to the existing `/:slug/wiki/*` resolver for unknown/unindexed ones (async-indexing lag self-heals). Backlinks panel is a right-rail tool on a new query hook. Autocomplete is a CM6 `autocompletion` source fed by the cached sync manifest, threaded into the editor like `openWikiLink`.

**Tech Stack:** React 19, TanStack Query, react-router, CodeMirror 6 (`@codemirror/autocomplete` already installed as an Atomic peer dep), vitest.

**Branch:** `feat/note-links-frontend` (this worktree — stacked on `feat/note-links-foundation` + `fix/spa-wikilink-routing`). All work in `frontend/`.

## Global Constraints

- `bun` for everything; lint via `./node_modules/.bin/biome ci src/` (NOT bunx); typecheck `bunx tsc --noEmit`; tests `bunx vitest run <files>`.
- Case-insensitive map lookups: the backend resolves case-insensitively; the frontend map must too (lowercase keys).
- A dangling/unresolved link NEVER 404s harder than today: fallback is always the `/:slug/wiki/*` route (which handles manifest-fresh notes), never a dead href.
- No new dependencies. Semantic HTML; no `!important`.
- Commit after each task; conventional commits.

---

### Task 1: Resolver map + direct hrefs

**Files:**
- Modify: `frontend/src/viewer/wiki-link.ts` (+ its test)
- Modify: `frontend/src/viewer/note-view.tsx`, `frontend/src/viewer/note-page.tsx` (+ note-view.test.tsx)
- Modify: the `Note` type where `useNote`'s payload is typed (grep `interface Note` under `frontend/src/api/`)

**Interfaces:**
- Produces: `interface NoteLinkEdge { target_text: string; target_note_id: string | null; target_attachment_id: string | null; target_path: string | null; alias: string | null; anchor: string | null; link_type: "wikilink" | "embed"; dangling: boolean }`; `buildWikiMap(links: NoteLinkEdge[] | undefined): Map<string, NoteLinkEdge>` (keys = `target_text.toLowerCase()`); `wikiHref(raw, slug, map?)` — existing signature gains an optional map param: parse target; if `map.get(page.toLowerCase())` has `target_note_id` → `/${slug}/${target_note_id}${hash}`; else existing behavior (wiki fallback / inert / same-page hash).

- [ ] **Step 1: Failing tests** in `wiki-link.test.ts`:

```ts
describe("wikiHref with resolver map", () => {
	const map = buildWikiMap([
		{ target_text: "My Note", target_note_id: "n-1", target_attachment_id: null, target_path: "a/My Note.md", alias: null, anchor: null, link_type: "wikilink", dangling: false },
		{ target_text: "Ghost", target_note_id: null, target_attachment_id: null, target_path: null, alias: null, anchor: null, link_type: "wikilink", dangling: true },
	]);

	test("resolved target links straight to the note id", () => {
		expect(wikiHref("My Note", "v", map)).toBe("/v/n-1");
	});

	test("lookup is case-insensitive and keeps the heading hash", () => {
		expect(wikiHref("my note#Some Heading", "v", map)).toBe("/v/n-1#some-heading");
	});

	test("dangling target falls back to the wiki resolver route", () => {
		expect(wikiHref("Ghost", "v", map)).toBe("/v/wiki/Ghost");
	});

	test("target absent from the map falls back to the wiki resolver route", () => {
		expect(wikiHref("Brand New", "v", map)).toBe("/v/wiki/Brand%20New");
	});

	test("no map behaves exactly as before", () => {
		expect(wikiHref("My Note", "v")).toBe("/v/wiki/My%20Note");
	});
});
```

- [ ] **Step 2:** `bunx vitest run src/viewer/wiki-link.test.ts` → FAIL (buildWikiMap undefined).
- [ ] **Step 3:** Implement `buildWikiMap` + the optional-map param in `wiki-link.ts`. Add the `NoteLinkEdge` type there and re-export/reference from the api Note type (`links?: NoteLinkEdge[]` — optional: older cached payloads lack it).
- [ ] **Step 4:** Wire the map through:
  - `note-page.tsx`: `const wikiMap = useMemo(() => buildWikiMap(note?.links), [note?.links]);` — `resolveWikiLink`/`openWikiLink` pass it to `wikiHref`; deps arrays gain `wikiMap`.
  - `note-view.tsx`: NoteView gains a `links?: NoteLinkEdge[]` prop (NotePage passes `note.links`); `remarkPluginsFor(slug, map)` memoized on `[slug, map]`, hrefTemplate uses the map. NoteView's other call site (markdown-reference-panel) passes nothing — must keep compiling with the prop optional.
  - Add one note-view test: with a `links` prop resolving `My Note`→`n-1`, the anchor href is `/work/n-1`.
- [ ] **Step 5:** `bunx vitest run src/viewer/wiki-link.test.ts src/viewer/note-view.test.tsx src/viewer/note-page.test.tsx` → PASS; `bunx tsc --noEmit` clean.
- [ ] **Step 6:** Commit `feat(spa): direct uuid wikilink hrefs from note_links payload`.

---

### Task 2: Backlinks panel

**Files:**
- Modify: `frontend/src/api/queries.ts` (new hook)
- Create: `frontend/src/viewer/backlinks-panel.tsx` + `backlinks-panel.test.tsx`
- Modify: wherever right-rail tools register (read `frontend/src/layout/right-tools-context.tsx` + how `note-toc.tsx` / the reference panel plug in via `useRightTools`/`setSlot` in note-page.tsx — follow that exact pattern)

**Interfaces:**
- Produces: `useBacklinks(noteId: string | null)` → `useQuery({ queryKey: ["backlinks", vaultId, noteId], queryFn: () => api.get<{ backlinks: Backlink[] }>(`/notes/by-id/${noteId}/backlinks`), enabled: noteId !== null, select: (d) => d.backlinks })` with `interface Backlink { source_note_id: string; source_path: string; source_title: string | null; alias: string | null; anchor: string | null }`; `<BacklinksPanel noteId={...} />` right-rail tool listing sources, each row a router `Link` to `/${slug}/${source_note_id}`.

- [ ] **Step 1: Failing tests** (`backlinks-panel.test.tsx`, mock `useBacklinks` like vault-route.test.tsx mocks queries): renders one row per backlink with title (fall back to path basename when title null); rows link to `/work/<source id>`; empty state text ("No backlinks yet") when list empty; loading state renders nothing/skeleton.
- [ ] **Step 2:** RED run.
- [ ] **Step 3:** Implement hook + panel (semantic list markup — `<nav aria-label="Backlinks"><ul>…`); register as a right-rail tool next to the ToC/reference panel following the existing `setSlot`/rail-view pattern in note-page.tsx (read it first; match, don't invent).
- [ ] **Step 4:** GREEN + tsc + biome.
- [ ] **Step 5:** Commit `feat(spa): backlinks panel (consumes note_links)`.

---

### Task 3: `[[` autocomplete in the editor

**Files:**
- Create: `frontend/src/viewer/editor/wiki-completion.ts` + `wiki-completion.test.ts`
- Modify: `frontend/src/viewer/editor/live-preview.ts` (thread a completion source), `note-editor.tsx` (prop), `note-page.tsx` (feed from `useSyncManifest`)

**Interfaces:**
- Produces:
  - Pure: `wikiCompletionCandidates(query: string, paths: string[]): Array<{ label: string; detail: string }>` — label = basename (no `.md`), detail = full path; rank: basename prefix match first, then basename substring, then path substring; case-insensitive; cap 50.
  - CM6: `wikiCompletionSource(getPaths: () => string[]): CompletionSource` — active only when the text before the cursor matches `/\[\[([^\]\[|#]*)$/` on the current line; `from` = start of the partial target; `apply` = `${target}]]` then place cursor after (use `apply: (view, completion, from, to)` writing `completion.label + "]]"` — but if the closing `]]` already exists immediately after the cursor, insert only the target). Escape/no-match never blocks typing (source returns null).
  - `LivePreviewOpts` gains `wikiCompletionPaths: () => string[]`; live-preview adds `autocompletion({ override: [wikiCompletionSource(opts.wikiCompletionPaths)], defaultKeymap: true })` from `@codemirror/autocomplete`. NoteEditor threads it like `openWikiLink` (props → decorationsFor → livePreviewExtensions; raw mode gets NO completion).
  - NotePage: `const { data: manifest } = useSyncManifest();` + a ref-stable `wikiCompletionPaths = useCallback(() => manifestPathsRef.current, [])` reading through a ref updated on manifest change — the editor extensions must NOT rebuild per manifest refetch (same reconfigure-avoidance reasoning as onView/onShortcutRef in note-editor.tsx).

- [ ] **Step 1: Failing tests** (`wiki-completion.test.ts`, pure part):

```ts
const paths = ["Deep/Sub/Alpha.md", "Alphabet.md", "notes/beta.md", "Gamma Ray.md"];

test("basename prefix matches rank before substring matches", () => {
	const labels = wikiCompletionCandidates("alp", paths).map((c) => c.label);
	expect(labels).toEqual(["Alpha", "Alphabet"]);
});

test("path substring matches included after basename matches", () => {
	const labels = wikiCompletionCandidates("notes", paths).map((c) => c.label);
	expect(labels).toEqual(["beta"]);
});

test("empty query lists everything capped", () => {
	expect(wikiCompletionCandidates("", paths)).toHaveLength(4);
});

test("case-insensitive", () => {
	expect(wikiCompletionCandidates("GAMMA", paths)[0]?.label).toBe("Gamma Ray");
});
```

Plus a source-level test constructing a real `EditorState` with `livePreviewExtensions` and asserting the extension composes without throwing (mirror live-preview.test.ts's mount pattern), and a trigger-regex unit test (exported `WIKI_TRIGGER_RE`): matches `"see [[Al"`, does NOT match `"see [Al"`, `"[[done]] Al"`, or inside `"[[a|b"`.

- [ ] **Step 2:** RED run.
- [ ] **Step 3:** Implement pure module, then thread through live-preview/note-editor/note-page (update their tests' opts fixtures with a `wikiCompletionPaths: () => []` noop, as done for openWikiLink).
- [ ] **Step 4:** GREEN: `bunx vitest run src/viewer/editor/ src/viewer/wiki-link.test.ts src/viewer/note-editor.test.tsx` + tsc + biome.
- [ ] **Step 5:** Commit `feat(spa): [[ autocomplete from vault manifest`.

---

### Task 4: Full verification + PR

- [ ] **Step 1:** `bun run test` (full suite) — zero failures; `bunx tsc --noEmit`; `./node_modules/.bin/biome ci src/`.
- [ ] **Step 2:** `git fetch origin` — report (not merge) drift of the two parent branches.
- [ ] **Step 3:** SINGLE-PR MODE (user decision 2026-08-04): this branch IS the PR branch — it contains the backend foundation commits, the fix/spa-wikilink-routing commits, and this frontend work. Push `feat/note-links-frontend`; ONE PR titled `feat: wikilink graph — note_links edges, resolution, backlinks, [[ autocomplete`, body: `Closes #591`, `Refs #592`, `Supersedes #1223` (close #1223 with a pointer comment after opening), links the vault spec, lists the three migrations + backfill deploy step (`rpc 'Engram.Links.Backfill.enqueue_all()'`), label **`phase/expand`**. Do NOT bump versions. Also file the two follow-up issues the ledger owes (BackfillContentHashHmac unique-stall; folder-rename/batch-move rebind fan-out).

## Self-review notes

- Spec coverage: direct hrefs ✓ (T1), fallback preserved ✓ (T1), dangling render — covered by fallback route (wiki resolver 404s with the app's standard page; the `new`-class styling refinement is deliberately deferred to keep this PR scoped — note in PR body). Backlinks panel ✓ (T2). Autocomplete ✓ (T3). Aliases/heading completion = spec follow-ups, not here.
- Type consistency: `NoteLinkEdge` defined once in wiki-link.ts, imported by api types + note-view + tests.
