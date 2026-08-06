# SPA wikilink resolution (`[[...]]` → note)

**Trigger:** web-app wikilinks go to a wrong URL / don't load, or you need to change how `[[Page]]`, `[[Page|alias]]`, `[[Page#Heading]]` resolve in the SPA.

## How it works (since PR #1223)

Note routes are id-keyed (`/:slug/:itemId`), but a wikilink names a note by
path or bare title. Bridging happens in three pieces, all in `frontend/src`:

1. **`viewer/wiki-link.ts`** (pure) — `parseWikiTarget` splits `Page#Heading`
   and slugs the heading with `github-slugger` (the SAME slugger rehype-slug
   uses, so the hash lands on a real anchor). `resolveWikiTarget` applies
   Obsidian rules against a `{id, path}` list: exact path (with/without
   `.md`) first, then vault-wide basename, shortest path wins, all
   case-insensitive. `wikiHref` builds `/:slug/wiki/<segment-encoded target>`.
2. **`viewer/wiki-link-redirect.tsx`** at route `/:slug/wiki/*` — fetches
   `GET /api/sync/manifest` (`useSyncManifest`, react-query, 30s staleTime;
   the manifest is the one endpoint with the vault-wide path→id inventory)
   and `<Navigate replace>`s to `/:slug/:id`, hash preserved. Unresolvable →
   NotFoundPage. Manifest is only fetched when a wikilink is followed.
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
- An unresolved link 404s **nested inside the app layout** (NotFoundPage as a
  child route) — looks odd but matches how the vault-slug 404 renders. Check
  for a typo between the link target and the note name before suspecting the
  resolver.
- Create-note-on-unresolved-link (Obsidian's behavior) is deliberately NOT
  implemented; unresolved targets 404.
