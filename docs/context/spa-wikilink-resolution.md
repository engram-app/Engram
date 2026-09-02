# SPA wikilink resolution (`[[...]]` → note)

**Trigger:** web-app wikilinks go to a wrong URL / don't load, or you need to change how `[[Page]]`, `[[Page|alias]]`, `[[Page#Heading]]` resolve in the SPA.

## How it works (since PR #1223; `/wiki/*` route removed 2026-09-02)

Note routes are id-keyed (`/v/:slug/:itemId`), but a wikilink names a note by
path or bare title. Bridging happens in three pieces, all in `frontend/src`:

1. **`viewer/wiki-link.ts`** (pure) — `parseWikiTarget` splits `Page#Heading`
   and slugs the heading with `github-slugger` (the SAME slugger rehype-slug
   uses, so the hash lands on a real anchor). `resolveWikiTarget` applies
   Obsidian rules against a `{id, path}` list: exact path (with/without
   `.md`) first, then vault-wide basename, shortest path wins, all
   case-insensitive. A RESOLVED target gets `/v/:slug/:id` (+ heading hash);
   an UNRESOLVED one gets `engram-new:<page>` — a sentinel, not a URL.
2. **Create-on-click** — `wikiCreateTarget` recognizes the sentinel and both
   producers call NotePage's `createWikiTarget`, which derives the path via
   `wikiCreatePath` (bare target → vault root, `[[Folder/Note]]` → that
   folder) and mints the note through `useCreateNote`, passing
   `renameOnArrive: false` because the link already supplied the name. This is
   Obsidian's behavior.
3. **Two producers, one helper** — Reading mode (`note-view.tsx`
   remark-wiki-link config) and the CodeMirror editor (`note-page.tsx`
   `resolveWikiLink` → Atomic `wikiLinks`) both emit via `wikiHref`. Keep
   them in lockstep.

## Traps

- **remark-wiki-link's default `pageResolver` mangles names**: `My Note` →
  `my_note` (spaces→underscores, lowercased). We pass identity
  (`(name) => [name]`). If you drop that option, links silently break again.
- `aliasDivider: "|"` must stay set — the package default is `:`.
- NoteView renders in the markdown reference panel too, **outside** any vault
  route; `wikiHref` returns `"#"` when there's no slug (inert anchor), so
  don't assume a slug exists where NoteView mounts.
- Reading-mode internal anchors go through react-router `Link` (the `a`
  component override in note-view.tsx); editor-mode click-to-open goes through
  `getAppRouter().navigate` (live-preview.ts onOpen). A plain `<a>` /
  `window.location.assign` full-page-reloads the SPA — both paths did exactly
  that once; don't regress it.
- **There is no `/v/:slug/wiki/*` route.** It existed until 2026-09-02 and
  rendered a `"X" doesn't exist yet.` interstitial with a Create button. It is
  deleted in the React router, the Phoenix router, and
  `wiki-link-redirect.tsx`; both wiki URL shapes are listed under
  `spa-routes.json`'s `mustNotResolve`, so re-adding one fails the parity
  tests. If you are reading about it in an older doc or comment, it is gone.
- A typo'd target now CREATES a note rather than 404ing, which is the Obsidian
  behavior but does mean a mistyped `[[Lnik]]` leaves a stray empty note.
- `wikiCreatePath` takes an already-parsed page and must not re-split on `#`:
  `#` is legal in a note path here, and re-parsing turned `[[C# Notes]]` into
  an offer to create `C.md`.
