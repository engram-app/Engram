# Vault Management Settings Page — Design

- **Date:** 2026-05-28
- **Status:** Design (pending user review)
- **Repo:** `engram-app/engram` (Phoenix backend + React frontend at `frontend/`)
- **Branch:** `feat/vault-management-settings`

## Summary

Add a **Vaults** section to the web app settings page where a user can see all
their vaults and manage them: rename, set default, create, and delete. Delete is
a **soft delete with a 30-day grace window**, after which the vault is permanently
purged. Soft-deleted vaults appear in a "Recently deleted" list with their purge
date and a Restore action. On soft-delete the user is emailed a notice with a link
back to the page, where they can optionally **purge immediately** instead of waiting
out the grace window.

The backend already implements the soft-delete + 30-day scheduled cleanup. This
feature fills the gaps around it (list trash, restore, purge-now, email) and builds
the entire frontend surface.

## Context: what already exists

- `Engram.Vaults.Vault` schema has a `deleted_at` column (soft delete) — no new
  column needed. (`lib/engram/vaults/vault.ex`)
- `Vaults.delete_vault/2` soft-sets `deleted_at`, clears `is_default`, promotes the
  next oldest vault to default, and **enqueues `CleanupVault` scheduled 30 days out**.
  (`lib/engram/vaults.ex:291`)
- `Engram.Workers.CleanupVault` hard-deletes the vault's data (Qdrant points, DB rows,
  storage blobs) and **self-skips if `deleted_at` is nil** (i.e. restored).
  (`lib/engram/workers/cleanup_vault.ex`, `@retention_days 30`)
- `Vaults.list_vaults/1` returns only non-deleted vaults (filters `is_nil(deleted_at)`).
- `Vaults.update_vault/3` already supports rename / description / `is_default` — covers
  rename + set-default with **no backend change**.
- `Vaults.create_vault/2` exists with a billing cap check — covers create with no change.
- Email subsystem (`Engram.Mailer`) funnels through a provider that defaults to
  `Engram.Email.NoOp` (logs + returns `:ok`) and switches to Resend only when
  `RESEND_API_KEY` is set. **Self-host email gating is therefore automatic** — calling
  the mailer on a self-host install is a safe no-op; no new flag required.
- Existing settings sections are registered in `frontend/src/settings/sections.ts` and
  routed in `frontend/src/router.tsx`; section pages follow the
  `SettingsSectionCard` pattern (see `account-page.tsx`).
- A vault switcher already exists at `frontend/src/layout/vault-switcher.tsx`; active
  vault state in `frontend/src/api/active-vault.ts`; vault queries in
  `frontend/src/api/queries.ts`.

## Decisions (from brainstorming)

1. **Delete-only with a 30-day grace** (not a separate archive-forever state). Reuses
   the existing `deleted_at` + `CleanupVault` machinery.
2. **Page scope:** list vaults; delete (soft); restore from trash; rename/edit;
   create / set default. All on one page.
3. **Trash UX:** one page, two sections — *Active vaults* on top, *Recently deleted*
   below (with purge date + Restore).
4. **Guardrails:**
   - **Block restore when over plan cap** — if restoring would exceed the user's vault
     cap, refuse with a clear message (upgrade / delete another).
   - **Type-to-confirm delete** — destructive actions require typing the vault name.
   - **Last-vault delete is allowed** (NOT blocked) — so the zero-vault state must
     degrade gracefully (see below).
5. **Email on soft-delete** with an optional **purge-now** path. The email button is a
   **navigational link to the authed settings page**, not a destructive link —
   industry-standard pattern that avoids email-scanner prefetch nuking data. The actual
   purge is a `POST` behind type-to-confirm in the app.
6. **Self-host:** no special branching — the `NoOp` mail provider already suppresses
   email when no provider is configured.

## Backend design

All endpoints live behind the existing `authenticated` pipeline alongside the other
`/vaults` routes (`router.ex` ~155-161). Controller: `VaultsController`.

### 1. List soft-deleted vaults

- **Context:** `Vaults.list_deleted_vaults(user)` — mirror of `list_vaults/1` but
  `where: not is_nil(v.deleted_at)`, decrypt names, order by `deleted_at` desc.
- **Endpoint:** `GET /vaults?deleted=true` — `VaultsController.index` branches on the
  `deleted` param. Default (no param) is unchanged (active vaults only).
- **JSON:** deleted-vault payload includes `deleted_at` and a computed
  `purge_at = deleted_at + 30 days` so the UI can show the purge date without
  duplicating the retention constant.

### 2. Restore

- **Endpoint:** `POST /vaults/:id/restore` → `VaultsController.restore`.
- **Context:** `Vaults.restore_vault(user, vault_id)`:
  1. Fetch a **soft-deleted** vault owned by the user; otherwise `{:error, :not_found}`.
  2. **Billing cap check:** count active vaults; if `active_count + 1` exceeds the
     vault cap, return `{:error, :limit_exceeded}`.
  3. Clear `deleted_at` (set nil). Leave `is_default = false` (the user re-sets default
     explicitly; another vault was promoted on delete).
  4. Emit vault-count telemetry (`:restored`).
  - The pending `CleanupVault` job becomes a no-op once `deleted_at` is nil — no need to
    cancel the Oban job.
- **Controller mapping:** `:limit_exceeded → 403` with a JSON error message;
  `:not_found → 404`; success `200` with the restored vault JSON.

### 3. Purge now (immediate hard delete)

- **Endpoint:** `POST /vaults/:id/purge` → `VaultsController.purge`.
- **Context:** `Vaults.purge_vault(user, vault_id)`:
  1. Fetch a **soft-deleted** vault owned by the user; otherwise `{:error, :not_found}`.
     (Only already-soft-deleted vaults can be purged — you cannot skip the soft-delete
     step.)
  2. Run cleanup immediately by enqueuing `CleanupVault` with `scheduled_at: now`
     (preferred over calling `perform_cleanup` inline, so the destructive work runs in
     the `:cleanup` queue with retries, off the request path).
- **Controller mapping:** `:not_found → 404`; success `200`.

### 4. CleanupVault age guard (restore→re-delete bug fix)

Today `CleanupVault.perform_cleanup` checks only `is_nil(deleted_at)`. A
restore-then-re-delete cycle leaves an **earlier-scheduled** job that would fire at
`delete₁ + 30d` and purge early. Fix the guard:

```
cond do
  is_nil(vault.deleted_at)                                  -> :ok        # restored
  DateTime.diff(now, vault.deleted_at, :second) < retention -> {:snooze, secs_until_due}
  true                                                      -> run_cleanup(vault)
end
```

`{:snooze, secs}` reschedules the same Oban job until the *current* `deleted_at` is
genuinely ≥30 days old, making cleanup idempotent across restore/re-delete cycles.
The explicit purge-now path bypasses this because it enqueues a fresh job whose intent
is immediate; the snooze only protects the auto-scheduled path. (Implementation note:
purge-now sets the same retention math to zero by scheduling `now` — verify the age
guard does not snooze a deliberate purge. Simplest: purge enqueues with a flag/arg, e.g.
`%{force: true}`, that skips the age check.)

### 5. Deletion-notice email

- **Template:** `Engram.Mailer.send_vault_deletion_notice(user, vault_name, purge_date, manage_url)`
  — MJML body following the existing template pattern (see `send_inactivity_warning_*`).
  Content: "Your vault *<name>* was deleted and will be permanently removed on
  *<purge_date>*. Changed your mind? Restore it. Want it gone now? Delete it
  permanently." with a single button linking to `manage_url`.
- **`manage_url`:** `https://app.engram.page/settings/vaults?highlight=<vault_id>` (host
  from existing app-URL config). Navigational only — no token, no destructive GET.
- **Trigger:** enqueue a small Oban worker (`VaultDeletedEmail`, queue `:mailers` or the
  existing mailer queue) from `delete_vault/2` after the soft-delete commits, so email
  send latency/failure never affects the DELETE response. The worker resolves the user
  email and calls the mailer; on self-host the `NoOp` provider drops it.

## Frontend design (`frontend/src/`)

### Nav + routing

- Add a `vaults` entry to `settings/sections.ts` (always shown, like `api-keys`), with a
  label "Vaults" and an icon.
- Add `/settings/vaults` → `VaultsPage` in `router.tsx`.

### `settings/vaults-page.tsx`

`<article>` header ("Vaults" + description), then two `SettingsSectionCard`s:

- **Active vaults**
  - Row per active vault: name (inline-editable → `useUpdateVault`), a default badge or
    a "Set default" action (`useUpdateVault` with `is_default: true`), and a **Delete**
    button (opens type-to-confirm dialog).
  - A **"New vault"** button → create dialog (name + optional description → `useCreateVault`).
- **Recently deleted** (rendered only when non-empty)
  - Row per soft-deleted vault: name, "Purges \<formatted purge_at\>", a **Restore**
    button (disabled with tooltip when restoring would exceed the cap), and a **Delete
    permanently** button (type-to-confirm → `usePurgeVault`).

### Dialogs

- **Delete (soft):** `AlertDialog` requiring the user to type the vault name to enable
  the confirm button → `useDeleteVault`.
- **Delete permanently (purge):** same type-to-confirm component, stronger copy
  ("This cannot be undone") → `usePurgeVault`.
- **Create:** small form `Dialog` (name + optional description).

### Deep-link from email

- `VaultsPage` reads `?highlight=<vaultId>` and scrolls to / briefly highlights the
  matching row (likely in the Recently deleted section). Purely cosmetic; no action runs
  automatically.

### React Query hooks (`api/queries.ts`)

| Hook | Call | Invalidates |
|------|------|-------------|
| `useDeletedVaults()` | `GET /vaults?deleted=true` | — (query key `['vaults','deleted']`) |
| `useDeleteVault()` | `DELETE /vaults/:id` | `['vaults']`, `['vaults','deleted']` |
| `useRestoreVault()` | `POST /vaults/:id/restore` | `['vaults']`, `['vaults','deleted']`; toast on 403 `limit_exceeded` |
| `usePurgeVault()` | `POST /vaults/:id/purge` | `['vaults','deleted']` |
| `useUpdateVault()` | `PATCH /vaults/:id` | `['vaults']` |
| `useCreateVault()` | `POST /vaults` | `['vaults']` |

`Vault` type gains optional `deleted_at?: string | null` and `purge_at?: string` (present
only in the deleted listing).

### Zero-vault state (last-vault delete is allowed)

Because deleting the only vault is permitted, the app can reach an active-vault-count of
zero. Audit `vault-switcher.tsx` + the main layout / note browser and the
`active-vault.ts` store so that:

- a null active vault does not crash any view, and
- the note browser / switcher shows a clear empty state ("No vaults — create one") with a
  CTA to the create-vault dialog (or `/settings/vaults`).

This is the main new non-obvious risk introduced by not blocking last-vault delete.

## API contract additions

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `GET` | `/vaults?deleted=true` | authenticated | List soft-deleted vaults (+`purge_at`) |
| `POST` | `/vaults/:id/restore` | authenticated | Clear `deleted_at` (cap-checked) |
| `POST` | `/vaults/:id/purge` | authenticated | Immediate hard delete of a soft-deleted vault |

(Existing: `GET/POST /vaults`, `GET/PATCH/DELETE /vaults/:id`, `POST /vaults/register`.)

## Testing (TDD — tests written first)

### Backend (ExUnit)

- `list_deleted_vaults/1` returns only soft-deleted vaults, decrypted, with `purge_at`.
- `restore_vault/2`: clears `deleted_at`; returns `:limit_exceeded` when over cap;
  `:not_found` for an active vault, a missing vault, or another user's vault.
- `purge_vault/2`: enqueues immediate cleanup for a soft-deleted vault; `:not_found`
  otherwise.
- `CleanupVault`: **snoozes** when `deleted_at` is <30d old (restore→re-delete cycle does
  not purge early); **purges** when ≥30d; **skips** when restored (`deleted_at` nil);
  **force-purges** immediately when invoked via the purge path.
- Controller: `GET /vaults?deleted=true` (shape + `purge_at`); `POST /restore`
  (200 / 403 over cap / 404); `POST /purge` (200 / 404).
- Mailer: `send_vault_deletion_notice` renders and routes through the provider;
  no-ops under `NoOp`; suppressed addresses skipped.

### Frontend (match existing test conventions)

- `VaultsPage` renders Active + Recently deleted sections from query data.
- Delete confirm button is disabled until the vault name is typed correctly.
- Restore button is disabled (with tooltip) when over cap; enabled otherwise.
- Hooks invalidate the correct query keys on success.
- `?highlight=<id>` scrolls to / highlights the row.

## Out of scope (YAGNI)

- Per-vault note counts (backend does not return them yet).
- Archive-forever state (explicitly rejected in favor of delete-with-grace).
- Bulk select / bulk delete.
- Tokened one-click purge from email (rejected for the safer link-to-app pattern).
- Configurable retention window (fixed at 30 days, the existing constant).

## Risks / notes

- **Zero-vault state** is the primary new risk — must be handled in the layout audit.
- **Force-purge vs age-guard interaction** — ensure the deliberate purge path is not
  snoozed by the age guard (use an explicit `force` arg).
- Email host/URL must come from the existing app-URL config, not be hardcoded.
