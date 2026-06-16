# Attachments in the Web File Tree — Phase 1 (display + preview)

**Date:** 2026-06-14
**Status:** Design — approved for planning
**Repo:** `engram` (backend + `frontend/`), single PR
**Branch:** `feat/attachments-in-file-tree`

## Problem

The web SPA file tree (`frontend/src/viewer/tree/`) is built from **folders +
notes only**. Engram stores vault files as two distinct backend concepts:

- **Notes** — markdown + canvas, full rows in the `notes` table.
- **Attachments** — binaries (images, PDFs, …), encrypted blobs in S3 with
  metadata in the `attachments` table.

Attachments are never surfaced in the tree. Users with images/PDFs in their
vault cannot see or open them on the web. This is Phase 1 of a larger
"full attachment management on web" goal — it ships **display + preview**.
Later phases add delete/rename (Phase 2) and upload (Phase 3).

## Scope

**In:** list attachments per vault; show them in the tree with type-aware
icons; click to open a read-only preview (image inline, PDF embedded, other
types → download link).

**Out (later phases):** upload, delete, rename, move, drag-drop, paid-tier
upload gating. No changes to the sync protocol or the plugin.

## Constraints / facts

- Attachment `path` is HMAC-encrypted at rest — you cannot glob or `LIKE` it.
  Listing requires decrypting each row's path (the existing `list_changes`
  read path already does this).
- The `attachments` metadata serializer exposes **no client-facing uuid**;
  `path` is the unique key within a vault. The tree will key attachment rows
  by encoded path, and preview fetches by path via the existing
  `GET /api/attachments/*path` blob endpoint.
- Folders are derived backend-side from notes + explicit folder markers
  (`Notes.list_folders_with_counts` + `list_folder_markers`). Attachments are
  **not** a folder source — so a folder containing only attachments is absent
  from the `/api/folders` response. The frontend must synthesize those folders
  (decision below).
- Binary attachments are a paid-tier feature (free is text-only). So these
  files exist only for paid / self-host users. The list endpoint is **not**
  feature-gated — free-tier simply returns `[]`.

## Backend

### New endpoint: `GET /api/attachments`

Returns non-deleted attachment metadata for the active vault:

```json
{ "attachments": [
  { "path": "diagrams/arch.png", "mime_type": "image/png",
    "size_bytes": 20481, "mtime": 1718300000.0, "updated_at": "2026-06-10T…Z" }
] }
```

- New context fn `Engram.Attachments.list_attachments/2` — same query/decrypt
  shape as `list_changes/3` but `where deleted_at IS NULL`, and omits the
  `deleted_at` field from output. (Refactor: `list_changes` can call a shared
  private builder so the decrypt logic lives in one place.)
- New `AttachmentsController.index/2`, serialized like `serialize_metadata/1`.
- Route on the vault-scoped pipeline (alongside `attachments/changes`):
  `get "/attachments", AttachmentsController, :index`. Must be declared
  **before** `get "/attachments/*path"` so it isn't swallowed by the splat.
- No `Billing.check_feature` gate — returns whatever rows exist.

### Tests
- `Engram.AttachmentsTest`: `list_attachments/2` returns non-deleted only,
  decrypts paths, scopes by user+vault (tenant isolation), excludes
  soft-deleted rows.
- `AttachmentsControllerTest`: `GET /api/attachments` shape + auth boundary
  (401 unauthenticated) + empty list for a vault with no attachments.

## Frontend

### 1. Tree item type (`viewer/tree/types.ts`)
Add a third variant:
```ts
| { kind: 'attachment'; path: string; mime: string; size: number }
```
itemId encoding gains an `a:` prefix carrying the **encoded path** (no uuid):
`formatItemId`/`parseItemId`/`ParsedItemId` extended; round-trip preserved
(path may contain `/`, so encode each segment, join with `/`, and split only
on the first `:` as today). Tests in `types.test.ts`.

### 2. Query (`api/queries.ts`)
`useAttachments(vaultId)` → `GET /attachments`, cached like folder-notes
(`staleTime` reuse). Type `AttachmentSummary { path; mime_type; size_bytes;
mtime; updated_at }`.

### 3. Loader (`viewer/tree/loader.ts`)
- Bucket attachments by `dirname(path)`:
  - `""` (no slash) → vault root children.
  - otherwise → the folder row whose `name` equals that dirname.
- **Synthesize missing folders.** Build the set of dirnames from attachment
  paths; for any not present in `folders`, synthesize folder rows (with synthetic
  ids + parent linkage up the chain to root) so every attachment is reachable.
  Synthetic folders get `count` = contained attachment count and merge with real
  folders by path (a real folder always wins its id). Keep this in a small,
  separately-tested helper (`synthesizeFolders(folders, attachments)`).
- Attachments sort alongside notes by filename under the active sort key.

### 4. Tree row (`viewer/tree/tree-row.tsx`)
Render `kind: 'attachment'` as `<Link to={/attachment/<encoded>}>` with:
- a mime-based icon (image / pdf / generic-file),
- an uppercase extension badge (reuse the note-row badge pattern).

### 5. Preview page + route
- New lazy `viewer/attachment-page.tsx`, route `{ path: '/attachment/*',
  element: suspended(<AttachmentPage/>) }` inside `AppLayout` (same shell as
  `/note/:id`), so the tree sidebar stays mounted.
- Reads the splat path, fetches via `api.getBlob('/attachments/' + encoded)`
  (reuse `AttachmentImg`'s blob-URL + revoke lifecycle):
  - `image/*` → `<img>`,
  - `application/pdf` → `<iframe>` (or `<object>`),
  - else → filename + size + a download link + "Preview not supported".
- Loading + error (404 / fetch fail) states mirror `AttachmentImg`.

### Tests
- `loader.test.ts`: attachments bucket to root vs folder; sort interleave with
  notes; **synthesize** path (attachment-only folder appears, nested chain,
  real-folder id preserved on collision).
- `types.test.ts`: `a:` round-trip incl. paths with `/` and spaces.
- `tree-row.test.tsx`: attachment row renders a `/attachment/...` link + icon + badge.
- `attachment-page.test.tsx`: image branch, pdf branch, unsupported branch,
  loading + error states.

## Data flow

```
GET /api/attachments ──▶ useAttachments() ──▶ loader buckets by dirname
                                              + synthesizeFolders()
                                                     │
   folders + notes (existing) ────────────────────────┤
                                                     ▼
                                          Headless-Tree rows
                                                     │ click attachment
                                                     ▼
                              /attachment/*path ──▶ AttachmentPage
                                                     │ getBlob(/attachments/*path)
                                                     ▼
                                        <img> | <iframe> | download
```

## Out of scope / deferred

- Phase 2: delete + rename + move (reuse tree-actions + wire backend delete).
- Phase 3: drag-drop upload + paid-tier upload gating in the web UI.
- Thumbnails / image previews in the tree row itself (open-only for now).
- Pagination of the attachment list (vaults with thousands of attachments) —
  Phase 1 returns the full list; revisit if it becomes a payload concern.

## Testing strategy

TDD per unit: write the failing backend context/controller test and the
frontend loader/types/row/page tests first, then implement. Backend via
`mix test`; frontend via `bun test` (run `lint:obsidian`/`lint:css`/biome
locally before pushing per project rules).
