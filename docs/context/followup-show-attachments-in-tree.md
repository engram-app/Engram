# Follow-up: show attachments in the file tree

**Status:** Backlog — deferred from the mobile-document-view work (PR #115, 2026-05-12).

## The gap

`FolderTree` (`frontend/src/viewer/folder-tree.tsx`) and `useFolderNotes` (`frontend/src/api/queries.ts`) only call `GET /folders/:path/notes`, which hits `Engram.Notes.list_notes_in_folder/3` and queries the `notes` table only. PDFs, images, and other binaries live in the separate `attachments` table — they never appear in the tree, even when the user has uploaded them via the plugin and they are stored under the same folder path.

The user noticed this while testing the mobile layout: their vault has PDFs that don't show up alongside `.md` files.

## What the tree already does correctly

- Non-`.md` extension chip is wired in `NoteLeaf` (e.g. shows `PNG` on the right). It only fires for files that *do* come back from the notes endpoint — so if/when a vault has non-md files stored as notes, the chip already works.

## What's needed to close the gap

1. **Backend endpoint** to list attachments by folder. Likely shape: `GET /folders/:path/attachments` returning `[{ path, mime, size, mtime }]`. Lives in `lib/engram_web/controllers/folders_controller.ex` (or a new `attachments_in_folder` route on `AttachmentsController`) and `Engram.Attachments.list_attachments_in_folder/3`.
2. **Frontend hook** `useFolderAttachments(folderPath)` paralleling `useFolderNotes`.
3. **Merge in `FolderFiles`/`RootFiles`**: combine notes + attachments, stable-sort by display name. Decide whether attachments and notes interleave alphabetically (Obsidian-like) or attachments group at the bottom.
4. **Different click handler** for attachments — they should open an attachment viewer route or trigger a download, not navigate to `/note/`. The existing `attachment-img.tsx` viewer pattern handles images via `engram-attachment:` URLs; a PDF viewer would need similar.
5. **Real-time sync** — when an attachment is uploaded/deleted, the tree should refresh. Hook into the existing channel/PubSub plumbing that note CRUD already uses.

## Scope estimate

Small backend slice (~1 hour), small frontend slice (~1 hour), plus design decisions about ordering and the attachment viewer behaviour. Probably one spec + one plan, not bundled into anything else.
