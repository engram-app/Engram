# Vault Settings Refinements — Design

> Refinement of the shipped vault-management feature (PR #345). See
> `2026-05-28-vault-management-design.md` for the base design.

**Goal:** Make the vault settings screen more scannable (table layout with file +
attachment counts) and make destructive delete clearer (modal that educates about
the 30-day soft-delete window, remote-only scope, with type-to-confirm + red trash
action).

## Motivation

The shipped page renders vaults as stacked rows with an inline type-to-confirm
delete. Two problems:

1. **Low scannability** — no at-a-glance sense of how much each vault holds.
2. **Delete clarity** — inline confirm doesn't explain consequences. Users don't
   know (a) it's recoverable for 30 days, (b) it only deletes the *remote* copy,
   not files already synced to their machines.

## Scope

### Backend

Surface per-vault content counts on the vault JSON (active + deleted lists).

- **Counts are active-only:** `notes.deleted_at IS NULL` and
  `attachments.deleted_at IS NULL`, scoped to `user_id` + `vault_id`. A
  soft-deleted vault keeps its child rows until purge, so trash counts honestly
  reflect "N files that will be permanently deleted."
- **Batched, no N+1:** one `GROUP BY vault_id` query per table over the listed
  vault ids, merged into a `%{vault_id => %{notes: n, attachments: m}}` map.
- `vault_json/2` gains a counts argument; `index` (both the default and
  `deleted=true` clauses) computes the batched map and passes per-vault counts.
- Single-vault responses (`create`, `update`, `restore`) compute counts for that
  one vault. A freshly created vault is `0/0`; this keeps the JSON shape uniform
  and the row correct before the list refetch lands.
- JSON fields: `note_count` (integer), `attachment_count` (integer).

### Frontend

**Dialog primitive.** Add `frontend/src/components/ui/dialog.tsx` — a shadcn
Dialog mirroring the existing `sheet.tsx` (both wrap `radix-ui`'s `Dialog`). No
new dependency.

**Active vaults → table.** Columns: Name (with default star + inline rename),
Files, Attachments, Actions. Actions: set-default (when not default), rename
(pencil), delete (red `Trash2` icon button, `variant="destructive"`,
`size="icon"`). Delete opens the modal instead of the old inline confirm.

**Trash → table.** Columns: Name, Files, Attachments, Deleted, Purges in,
Actions. Actions: restore (disabled when active count ≥ cap, existing rule),
delete permanently (red trash, `window.confirm` stays — it's already irreversible
and not the focus of this change).

**Delete modal** (`frontend/src/settings/vaults/delete-vault-dialog.tsx`):
- Title: `Delete "<vault name>"?`
- Body educates, in plain language:
  - Moves to trash; **recoverable for 30 days**, then permanently deleted.
  - States the file/attachment count being moved to trash.
  - **Remote-only:** "This only deletes the copy stored on Engram. Files already
    synced to your devices stay where they are."
- Type-to-confirm: an input that must match the vault name; the red
  **Delete vault** button (`Trash2` icon, destructive) stays disabled until it
  matches. Reuses the existing delete mutation.
- Cancel closes without action.

## Data Flow

1. `GET /api/vaults` and `GET /api/vaults?deleted=true` now return
   `note_count` + `attachment_count` per vault.
2. Table rows render counts directly from the query data.
3. Delete: trash icon → modal → type name → confirm → existing
   `useDeleteVault` mutation → list invalidates → row moves to trash table.

## Testing

- **Backend:** counts exclude soft-deleted children; counts scoped per-vault and
  per-user (no cross-tenant bleed); empty vault returns `0/0`; `deleted=true`
  list carries counts.
- **Frontend:** table renders counts; delete button disabled until typed name
  matches; matching name enables it and firing it calls the mutation; modal shows
  the remote-only + 30-day copy; trash table renders counts + purge date.

## Out of Scope

- Live-updating counts via websocket (counts are snapshot-at-fetch; list
  refetch on mutation is enough).
- Sorting/pagination of the vault table.
- Changing the permanent-delete (purge) confirm — stays `window.confirm`.
