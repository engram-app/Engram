# Vault Settings Refinements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface per-vault file/attachment counts, render the vault settings lists as tables, and replace the inline delete confirm with an educational modal (30-day window, remote-only, type-to-confirm, red trash action).

**Architecture:** Backend adds batched per-vault content counts to the vault JSON (active + trash). Frontend gains a `dialog.tsx` primitive and a `DeleteVaultDialog`, and both vault sections become tables.

**Tech Stack:** Elixir/Phoenix + Ecto (backend), React + TypeScript + TanStack Query + shadcn/ui + `radix-ui` Dialog + `lucide-react` (frontend). Tests: ExUnit + ex_machina factories (backend), Vitest + Testing Library (frontend).

**Worktree:** `engram/.worktrees/vault-settings-refinements` on branch `feat/vault-settings-refinements`.

**Note on test filtering:** This ExUnit setup filters by tag, not describe name. Run a single test with `mix test path:LINE` or `-n "tag"`, NOT `-o "name"`.

---

## File Structure

**Backend**
- Modify `lib/engram/vaults.ex` — add `content_counts_for/2` + `content_counts/2`.
- Modify `lib/engram_web/controllers/vaults_controller.ex` — thread counts into `vault_json` / `deleted_vault_json`.
- Test `test/engram/vaults_test.exs` — counts behavior.
- Test `test/engram_web/controllers/vaults_controller_test.exs` — JSON carries counts.

**Frontend**
- Modify `frontend/src/api/queries.ts` — add count fields to `Vault`.
- Create `frontend/src/components/ui/dialog.tsx` — Dialog primitive.
- Create `frontend/src/settings/vaults/delete-vault-dialog.tsx` + test.
- Modify `frontend/src/settings/vaults/active-vaults-section.tsx` + test — table + dialog wiring.
- Modify `frontend/src/settings/vaults/deleted-vaults-section.tsx` + test — table + counts.
- Modify `mix.exs` — version bump.

---

## Task 1: Backend — per-vault content counts

**Files:**
- Modify: `lib/engram/vaults.ex` (add functions near the `# ── List ──` region, after `list_for_ids/2`)
- Test: `test/engram/vaults_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram/vaults_test.exs` (new describe block, place after the create_vault describe):

```elixir
  describe "content_counts_for/2 and content_counts/2" do
    setup %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, a} = Vaults.create_vault(user, %{name: "Alpha"})
      {:ok, b} = Vaults.create_vault(user, %{name: "Beta"})
      %{a: a, b: b}
    end

    test "counts active notes and attachments per vault", %{user: user, a: a, b: b} do
      insert_pair(:note, user: user, vault: a)
      insert(:note, user: user, vault: b)
      insert(:attachment, user: user, vault: a)

      counts = Vaults.content_counts_for(user, [a, b])

      assert counts[a.id] == %{notes: 2, attachments: 1}
      assert counts[b.id] == %{notes: 1, attachments: 0}
    end

    test "excludes soft-deleted notes and attachments", %{user: user, a: a} do
      insert(:note, user: user, vault: a)
      insert(:note, user: user, vault: a, deleted_at: DateTime.utc_now(:second))
      insert(:attachment, user: user, vault: a, deleted_at: DateTime.utc_now(:second))

      assert Vaults.content_counts_for(user, [a])[a.id] == %{notes: 1, attachments: 0}
    end

    test "does not bleed across users", %{user: user, other_user: other, a: a} do
      insert(:note, user: other, vault: build(:vault, user: other))
      insert(:note, user: user, vault: a)

      assert Vaults.content_counts_for(user, [a])[a.id] == %{notes: 1, attachments: 0}
    end

    test "empty vault list returns empty map", %{user: user} do
      assert Vaults.content_counts_for(user, []) == %{}
    end

    test "content_counts/2 returns a single vault's counts", %{user: user, a: a} do
      insert(:note, user: user, vault: a)
      assert Vaults.content_counts(user, a.id) == %{notes: 1, attachments: 0}
    end

    test "content_counts/2 returns zeros for an empty vault", %{user: user, b: b} do
      assert Vaults.content_counts(user, b.id) == %{notes: 0, attachments: 0}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/engram/vaults_test.exs -n content_counts` (or just the file)
Expected: FAIL — `Vaults.content_counts_for/2` undefined.

- [ ] **Step 3: Write minimal implementation**

In `lib/engram/vaults.ex`, after `list_for_ids/2` (before the `# ── Get ──` region), add:

```elixir
  # ── Content counts ───────────────────────────────────────────────────────

  @zero_counts %{notes: 0, attachments: 0}

  @doc """
  Returns a map of `%{vault_id => %{notes: n, attachments: m}}` for the given
  vaults, counting only non-deleted notes/attachments owned by `user`.

  Two batched GROUP BY queries (one per table) — no N+1. Tenant scoping is the
  explicit `user_id == ^user_id` clause; RLS is bypassed (`skip_tenant_check:
  true`) for performance, matching `list_for_ids/2`. The clause MUST stay.
  """
  @spec content_counts_for(Engram.Accounts.User.t(), [Vault.t()]) ::
          %{integer() => %{notes: integer(), attachments: integer()}}
  def content_counts_for(%Engram.Accounts.User{id: user_id}, vaults) when is_list(vaults) do
    ids = Enum.map(vaults, & &1.id)
    do_content_counts(user_id, ids)
  end

  @doc """
  Returns `%{notes: n, attachments: m}` for a single vault id owned by `user`.
  """
  @spec content_counts(Engram.Accounts.User.t(), integer()) :: %{
          notes: integer(),
          attachments: integer()
        }
  def content_counts(%Engram.Accounts.User{id: user_id}, vault_id) do
    Map.get(do_content_counts(user_id, [vault_id]), vault_id, @zero_counts)
  end

  defp do_content_counts(_user_id, []), do: %{}

  defp do_content_counts(user_id, ids) do
    note_counts =
      from(n in Engram.Notes.Note,
        where: n.user_id == ^user_id and n.vault_id in ^ids and is_nil(n.deleted_at),
        group_by: n.vault_id,
        select: {n.vault_id, count(n.id)}
      )
      |> Repo.all(skip_tenant_check: true)
      |> Map.new()

    attachment_counts =
      from(a in Engram.Attachments.Attachment,
        where: a.user_id == ^user_id and a.vault_id in ^ids and is_nil(a.deleted_at),
        group_by: a.vault_id,
        select: {a.vault_id, count(a.id)}
      )
      |> Repo.all(skip_tenant_check: true)
      |> Map.new()

    Map.new(ids, fn id ->
      {id, %{notes: Map.get(note_counts, id, 0), attachments: Map.get(attachment_counts, id, 0)}}
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/engram/vaults_test.exs`
Expected: PASS (all, including the new describe).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/vaults.ex test/engram/vaults_test.exs
git commit -m "feat: per-vault note + attachment counts"
```

---

## Task 2: Backend — expose counts on vault JSON

**Files:**
- Modify: `lib/engram_web/controllers/vaults_controller.ex`
- Test: `test/engram_web/controllers/vaults_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram_web/controllers/vaults_controller_test.exs` (inside the existing `describe "index"` block — match the existing auth/setup conventions in that file; if a logged-in `conn` + `user` are provided by `setup`, reuse them):

```elixir
    test "index includes note_count and attachment_count", %{conn: conn, user: user} do
      vault = Engram.Repo.one!(from v in Engram.Vaults.Vault, where: v.user_id == ^user.id)
      insert(:note, user: user, vault: vault)
      insert(:note, user: user, vault: vault)
      insert(:attachment, user: user, vault: vault)

      resp = conn |> get(~p"/api/vaults") |> json_response(200)
      row = Enum.find(resp["vaults"], &(&1["id"] == vault.id))

      assert row["note_count"] == 2
      assert row["attachment_count"] == 1
    end
```

> If the test file lacks `import Ecto.Query` / factory imports, add them at the top following the file's existing style. If the setup doesn't already create a vault for `user`, create one with `insert(:vault, user: user)` and use that.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/engram_web/controllers/vaults_controller_test.exs -n index`
Expected: FAIL — `note_count` is nil (key absent).

- [ ] **Step 3: Write minimal implementation**

In `lib/engram_web/controllers/vaults_controller.ex`:

Replace the two `index/2` clauses (lines ~9-19) with:

```elixir
  def index(conn, %{"deleted" => "true"}) do
    user = conn.assigns.current_user
    vaults = Vaults.list_deleted_vaults(user)
    counts = Vaults.content_counts_for(user, vaults)

    json(conn, %{
      vaults: Enum.map(vaults, &deleted_vault_json(&1, Map.get(counts, &1.id, @zero_counts)))
    })
  end

  def index(conn, _params) do
    user = conn.assigns.current_user
    vaults = Vaults.list_vaults(user)
    counts = Vaults.content_counts_for(user, vaults)

    json(conn, %{
      vaults: Enum.map(vaults, &vault_json(&1, Map.get(counts, &1.id, @zero_counts)))
    })
  end
```

Add the module attribute near the top of the module (after `alias Engram.Vaults`):

```elixir
  @zero_counts %{notes: 0, attachments: 0}
```

Replace each single-vault call site so counts come from `Vaults.content_counts/2`. The call sites are at lines ~30, 54, 73, 115, 169, 172. In each, change `vault_json(vault, user)` to `vault_json(vault, Vaults.content_counts(user, vault.id))`. For example, in `create`:

```elixir
      {:ok, vault} ->
        conn
        |> put_status(201)
        |> json(%{vault: vault_json(vault, Vaults.content_counts(user, vault.id))})
```

Apply the same substitution to `show` (line ~54), the update success (line ~73), the encrypt/restore success (line ~115), and the register clauses (lines ~169 and ~172):

```elixir
          |> json(vault_json(vault, Vaults.content_counts(user, vault.id)) |> Map.put(:status, "created"))
```
```elixir
          json(conn, vault_json(vault, Vaults.content_counts(user, vault.id)) |> Map.put(:status, "existing"))
```

Rewrite the JSON builders (lines ~186-208) so they take a counts map instead of `user`:

```elixir
  defp vault_json(vault, counts) do
    %{
      id: vault.id,
      name: vault.name,
      description: vault.description,
      slug: vault.slug,
      is_default: vault.is_default,
      created_at: vault.created_at,
      encrypted: true,
      note_count: counts.notes,
      attachment_count: counts.attachments
    }
  end

  defp deleted_vault_json(vault, counts) do
    vault
    |> vault_json(counts)
    |> Map.merge(%{
      deleted_at: vault.deleted_at,
      purge_at: purge_at(vault.deleted_at)
    })
  end
```

> Verify no other call site passes `user` to `vault_json`/`deleted_vault_json` after this change: `grep -n "vault_json(" lib/engram_web/controllers/vaults_controller.ex`. Every call must now pass a counts map.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && mix test test/engram_web/controllers/vaults_controller_test.exs`
Expected: PASS (new test + all pre-existing).

Also run `cd backend && mix compile --warnings-as-errors` — must be clean (no unused `user` warning).

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/controllers/vaults_controller.ex test/engram_web/controllers/vaults_controller_test.exs
git commit -m "feat: surface vault content counts on vault JSON"
```

---

## Task 3: Frontend — add count fields to the Vault type

**Files:**
- Modify: `frontend/src/api/queries.ts:298-313` (the `Vault` interface)

- [ ] **Step 1: Edit the type**

In the `Vault` interface, add after `purge_at?`:

```ts
  note_count?: number
  attachment_count?: number
```

(Optional fields — older cached responses and the encryption endpoints predate them; the UI defaults to `0`.)

- [ ] **Step 2: Verify typecheck**

Run: `cd backend/frontend && bunx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/api/queries.ts
git commit -m "feat: add note_count/attachment_count to Vault type"
```

---

## Task 4: Frontend — Dialog primitive

**Files:**
- Create: `frontend/src/components/ui/dialog.tsx`

- [ ] **Step 1: Create the component**

```tsx
import * as React from "react"
import { Dialog as DialogPrimitive } from "radix-ui"
import { XIcon } from "lucide-react"

import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"

function Dialog({ ...props }: React.ComponentProps<typeof DialogPrimitive.Root>) {
  return <DialogPrimitive.Root data-slot="dialog" {...props} />
}

function DialogTrigger({ ...props }: React.ComponentProps<typeof DialogPrimitive.Trigger>) {
  return <DialogPrimitive.Trigger data-slot="dialog-trigger" {...props} />
}

function DialogClose({ ...props }: React.ComponentProps<typeof DialogPrimitive.Close>) {
  return <DialogPrimitive.Close data-slot="dialog-close" {...props} />
}

function DialogPortal({ ...props }: React.ComponentProps<typeof DialogPrimitive.Portal>) {
  return <DialogPrimitive.Portal data-slot="dialog-portal" {...props} />
}

function DialogOverlay({ className, ...props }: React.ComponentProps<typeof DialogPrimitive.Overlay>) {
  return (
    <DialogPrimitive.Overlay
      data-slot="dialog-overlay"
      className={cn(
        "fixed inset-0 z-50 bg-black/10 duration-100 supports-backdrop-filter:backdrop-blur-xs data-open:animate-in data-open:fade-in-0 data-closed:animate-out data-closed:fade-out-0",
        className
      )}
      {...props}
    />
  )
}

function DialogContent({
  className,
  children,
  showCloseButton = true,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Content> & { showCloseButton?: boolean }) {
  return (
    <DialogPortal>
      <DialogOverlay />
      <DialogPrimitive.Content
        data-slot="dialog-content"
        className={cn(
          "fixed left-1/2 top-1/2 z-50 grid w-full max-w-md -translate-x-1/2 -translate-y-1/2 gap-4 rounded-lg border bg-popover bg-clip-padding p-6 text-sm text-popover-foreground shadow-lg duration-200 data-open:animate-in data-open:fade-in-0 data-open:zoom-in-95 data-closed:animate-out data-closed:fade-out-0 data-closed:zoom-out-95",
          className
        )}
        {...props}
      >
        {children}
        {showCloseButton && (
          <DialogPrimitive.Close data-slot="dialog-close" asChild>
            <Button variant="ghost" className="absolute top-3 right-3" size="icon-sm">
              <XIcon />
              <span className="sr-only">Close</span>
            </Button>
          </DialogPrimitive.Close>
        )}
      </DialogPrimitive.Content>
    </DialogPortal>
  )
}

function DialogHeader({ className, ...props }: React.ComponentProps<"div">) {
  return <div data-slot="dialog-header" className={cn("flex flex-col gap-1", className)} {...props} />
}

function DialogFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="dialog-footer"
      className={cn("flex flex-col-reverse gap-2 sm:flex-row sm:justify-end", className)}
      {...props}
    />
  )
}

function DialogTitle({ className, ...props }: React.ComponentProps<typeof DialogPrimitive.Title>) {
  return (
    <DialogPrimitive.Title
      data-slot="dialog-title"
      className={cn("font-heading text-base font-medium text-foreground", className)}
      {...props}
    />
  )
}

function DialogDescription({
  className,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Description>) {
  return (
    <DialogPrimitive.Description
      data-slot="dialog-description"
      className={cn("text-sm text-muted-foreground", className)}
      {...props}
    />
  )
}

export {
  Dialog,
  DialogTrigger,
  DialogClose,
  DialogPortal,
  DialogOverlay,
  DialogContent,
  DialogHeader,
  DialogFooter,
  DialogTitle,
  DialogDescription,
}
```

- [ ] **Step 2: Verify typecheck**

Run: `cd backend/frontend && bunx tsc --noEmit`
Expected: PASS. (If `size="icon-sm"` is not a valid Button size, use `size="icon"` — check `button.tsx` variants.)

- [ ] **Step 3: Commit**

```bash
git add frontend/src/components/ui/dialog.tsx
git commit -m "feat: add shadcn Dialog primitive"
```

---

## Task 5: Frontend — DeleteVaultDialog

**Files:**
- Create: `frontend/src/settings/vaults/delete-vault-dialog.tsx`
- Test: `frontend/src/settings/vaults/delete-vault-dialog.test.tsx`

- [ ] **Step 1: Write the failing test**

```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const deleteMutate = vi.fn()
vi.mock('@/api/queries', () => ({
  useDeleteVault: () => ({ mutate: deleteMutate, isPending: false }),
}))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { DeleteVaultDialog } from './delete-vault-dialog'

const vault = {
  id: 7,
  name: 'Work',
  description: null,
  slug: 'work',
  is_default: false,
  created_at: '',
  encrypted: true,
  note_count: 142,
  attachment_count: 3,
}

describe('DeleteVaultDialog', () => {
  beforeEach(() => vi.clearAllMocks())

  it('educates about the 30-day window and remote-only scope', () => {
    render(<DeleteVaultDialog vault={vault} open onOpenChange={() => {}} />)
    expect(screen.getByText(/30 days/i)).toBeInTheDocument()
    expect(screen.getByText(/synced to your devices/i)).toBeInTheDocument()
    expect(screen.getByText(/142/)).toBeInTheDocument()
  })

  it('keeps the delete button disabled until the name is typed', async () => {
    render(<DeleteVaultDialog vault={vault} open onOpenChange={() => {}} />)
    const confirmBtn = screen.getByRole('button', { name: /delete vault/i })
    expect(confirmBtn).toBeDisabled()
    fireEvent.change(screen.getByLabelText(/type .*work.* to confirm/i), { target: { value: 'Work' } })
    expect(confirmBtn).toBeEnabled()
    fireEvent.click(confirmBtn)
    await waitFor(() => expect(deleteMutate).toHaveBeenCalledWith(7, expect.anything()))
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bunx vitest run src/settings/vaults/delete-vault-dialog.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the component**

```tsx
import { useEffect, useState } from 'react'
import { Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useDeleteVault, type Vault } from '@/api/queries'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function DeleteVaultDialog({
  vault,
  open,
  onOpenChange,
}: {
  vault: Vault
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const del = useDeleteVault()
  const [phrase, setPhrase] = useState('')

  useEffect(() => {
    if (!open) setPhrase('')
  }, [open])

  const noteCount = vault.note_count ?? 0
  const attachmentCount = vault.attachment_count ?? 0

  function confirmDelete() {
    del.mutate(vault.id, {
      onSuccess: () => {
        toast.success('Vault moved to trash')
        onOpenChange(false)
      },
      onError: () => toast.error('Delete failed'),
    })
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Delete "{vault.name}"?</DialogTitle>
          <DialogDescription>
            This vault holds {noteCount} {noteCount === 1 ? 'note' : 'notes'} and {attachmentCount}{' '}
            {attachmentCount === 1 ? 'attachment' : 'attachments'}.
          </DialogDescription>
        </DialogHeader>

        <ul className="space-y-2 text-sm text-muted-foreground">
          <li>
            It moves to trash and is <strong className="text-foreground">recoverable for 30 days</strong>, then
            permanently deleted.
          </li>
          <li>
            This only deletes the copy stored on Engram. Files already{' '}
            <strong className="text-foreground">synced to your devices</strong> stay where they are.
          </li>
        </ul>

        <form
          onSubmit={(e) => {
            e.preventDefault()
            confirmDelete()
          }}
        >
          <label className="block text-sm text-foreground">
            Type "{vault.name}" to confirm
            <input
              autoFocus
              className={inputClass}
              aria-label={`Type ${vault.name} to confirm`}
              value={phrase}
              onChange={(e) => setPhrase(e.target.value)}
            />
          </label>
          <DialogFooter className="mt-4">
            <Button type="button" variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button
              type="submit"
              variant="destructive"
              size="sm"
              disabled={phrase !== vault.name || del.isPending}
            >
              <Trash2 />
              Delete vault
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend/frontend && bunx vitest run src/settings/vaults/delete-vault-dialog.test.tsx`
Expected: PASS.

> If radix Dialog content doesn't render in jsdom without a portal target, the test still works because `DialogPortal` mounts to `document.body`. If `screen.getByText` can't find content, ensure the test asserts after `open` is true (it is).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/settings/vaults/delete-vault-dialog.tsx frontend/src/settings/vaults/delete-vault-dialog.test.tsx
git commit -m "feat: educational delete-vault confirmation dialog"
```

---

## Task 6: Frontend — Active vaults table

**Files:**
- Modify: `frontend/src/settings/vaults/active-vaults-section.tsx`
- Test: `frontend/src/settings/vaults/active-vaults-section.test.tsx`

- [ ] **Step 1: Update the test**

Replace the file body's tests with table-aware + dialog-aware versions. Update the mock to include the dialog hook usage (already `useDeleteVault`) and add counts to the fixtures:

```tsx
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const deleteMutate = vi.fn()
const updateMutate = vi.fn()
const vaults = [
  { id: 1, name: 'Work', description: null, slug: 'work', is_default: true, created_at: '', encrypted: true, note_count: 12, attachment_count: 3 },
  { id: 2, name: 'Personal', description: null, slug: 'personal', is_default: false, created_at: '', encrypted: true, note_count: 0, attachment_count: 0 },
]

vi.mock('@/api/queries', () => ({
  useVaults: () => ({ data: vaults, isLoading: false }),
  useDeleteVault: () => ({ mutate: deleteMutate, isPending: false }),
  useUpdateVault: () => ({ mutate: updateMutate, isPending: false }),
}))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { ActiveVaultsSection } from './active-vaults-section'

describe('ActiveVaultsSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('lists vaults with counts and marks the default', () => {
    render(<ActiveVaultsSection />)
    const workRow = within(screen.getByText('Work').closest('tr') as HTMLElement)
    expect(workRow.getByText('12')).toBeInTheDocument()
    expect(workRow.getByText('3')).toBeInTheDocument()
    expect(screen.getByText('Default')).toBeInTheDocument()
  })

  it('opens the delete dialog and deletes after typing the name', async () => {
    render(<ActiveVaultsSection />)
    const workRow = within(screen.getByText('Work').closest('tr') as HTMLElement)
    fireEvent.click(workRow.getByRole('button', { name: /delete .*work/i }))
    const confirmBtn = screen.getByRole('button', { name: /delete vault/i })
    expect(confirmBtn).toBeDisabled()
    fireEvent.change(screen.getByLabelText(/type .*work.* to confirm/i), { target: { value: 'Work' } })
    fireEvent.click(confirmBtn)
    await waitFor(() => expect(deleteMutate).toHaveBeenCalledWith(1, expect.anything()))
  })

  it('sets a non-default vault as default', () => {
    render(<ActiveVaultsSection />)
    fireEvent.click(screen.getByRole('button', { name: /set .*personal.* as default|set default/i }))
    expect(updateMutate).toHaveBeenCalledWith({ id: 2, is_default: true }, expect.anything())
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bunx vitest run src/settings/vaults/active-vaults-section.test.tsx`
Expected: FAIL — no `tr`, delete button label changed.

- [ ] **Step 3: Rewrite the component as a table**

```tsx
import { useState } from 'react'
import { Pencil, Star, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from '@/settings/account/section-card'
import { useVaults, useUpdateVault, type Vault } from '@/api/queries'
import { DeleteVaultDialog } from './delete-vault-dialog'

const inputClass =
  'block w-full rounded-md border border-input bg-card px-2 py-1 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function ActiveVaultsSection() {
  const { data: vaults, isLoading } = useVaults()
  const [deleteTarget, setDeleteTarget] = useState<Vault | null>(null)

  return (
    <SettingsSectionCard title="Vaults" description="Rename, set a default, or delete your vaults.">
      {isLoading && <p className="text-sm text-muted-foreground">Loading…</p>}
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-border text-left text-xs text-muted-foreground">
            <th className="py-2 font-medium">Name</th>
            <th className="py-2 text-right font-medium">Files</th>
            <th className="py-2 text-right font-medium">Attachments</th>
            <th className="py-2" aria-label="Actions" />
          </tr>
        </thead>
        <tbody className="divide-y divide-border">
          {(vaults ?? []).map((v) => (
            <VaultRow key={v.id} vault={v} onDelete={() => setDeleteTarget(v)} />
          ))}
          {!isLoading && (vaults ?? []).length === 0 && (
            <tr>
              <td colSpan={4} className="py-3 text-muted-foreground">
                No vaults yet.
              </td>
            </tr>
          )}
        </tbody>
      </table>

      {deleteTarget && (
        <DeleteVaultDialog
          vault={deleteTarget}
          open={deleteTarget !== null}
          onOpenChange={(open) => !open && setDeleteTarget(null)}
        />
      )}
    </SettingsSectionCard>
  )
}

function VaultRow({ vault, onDelete }: { vault: Vault; onDelete: () => void }) {
  const update = useUpdateVault()
  const [renaming, setRenaming] = useState(false)
  const [name, setName] = useState(vault.name)

  function saveName() {
    const next = name.trim()
    if (next && next !== vault.name) {
      update.mutate({ id: vault.id, name: next }, { onError: () => toast.error('Rename failed') })
    }
    setRenaming(false)
  }

  return (
    <tr>
      <td className="py-3">
        {renaming ? (
          <input
            autoFocus
            className={inputClass}
            value={name}
            aria-label={`Rename ${vault.name}`}
            onChange={(e) => setName(e.target.value)}
            onBlur={saveName}
            onKeyDown={(e) => e.key === 'Enter' && saveName()}
          />
        ) : (
          <span className="flex items-center gap-2">
            <span className="font-medium text-foreground">{vault.name}</span>
            {vault.is_default && (
              <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">Default</span>
            )}
          </span>
        )}
      </td>
      <td className="py-3 text-right tabular-nums text-muted-foreground">{vault.note_count ?? 0}</td>
      <td className="py-3 text-right tabular-nums text-muted-foreground">{vault.attachment_count ?? 0}</td>
      <td className="py-3">
        <span className="flex items-center justify-end gap-1">
          {!vault.is_default && (
            <Button
              variant="ghost"
              size="icon-sm"
              title={`Set ${vault.name} as default`}
              aria-label={`Set ${vault.name} as default`}
              onClick={() =>
                update.mutate(
                  { id: vault.id, is_default: true },
                  { onError: () => toast.error('Could not set default') },
                )
              }
            >
              <Star />
            </Button>
          )}
          <Button
            variant="ghost"
            size="icon-sm"
            title={`Rename ${vault.name}`}
            aria-label={`Rename ${vault.name}`}
            onClick={() => setRenaming(true)}
          >
            <Pencil />
          </Button>
          <Button
            variant="destructive"
            size="icon-sm"
            title={`Delete ${vault.name}`}
            aria-label={`Delete ${vault.name}`}
            onClick={onDelete}
          >
            <Trash2 />
          </Button>
        </span>
      </td>
    </tr>
  )
}
```

> If `size="icon-sm"` is not in `button.tsx`, use `size="icon"`. Verify with `grep "icon" src/components/ui/button.tsx`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend/frontend && bunx vitest run src/settings/vaults/active-vaults-section.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/settings/vaults/active-vaults-section.tsx frontend/src/settings/vaults/active-vaults-section.test.tsx
git commit -m "feat: render active vaults as a table with counts + modal delete"
```

---

## Task 7: Frontend — Trash table

**Files:**
- Modify: `frontend/src/settings/vaults/deleted-vaults-section.tsx`
- Test: `frontend/src/settings/vaults/deleted-vaults-section.test.tsx`

- [ ] **Step 1: Update the test**

Read the existing `deleted-vaults-section.test.tsx` first to preserve its mocks (`useDeletedVaults`, `useVaults`, `useBillingConfig`, `useRestoreVault`, `usePurgeVault`, `react-router`). Add counts to fixtures and assert table cells. Add/keep:

```tsx
  it('shows counts and purge date in the trash table', () => {
    render(<DeletedVaultsSection />)
    const row = within(screen.getByText('Old').closest('tr') as HTMLElement)
    expect(row.getByText('5')).toBeInTheDocument()       // note_count
    expect(row.getByText('2')).toBeInTheDocument()       // attachment_count
    expect(row.getByText(/purge/i)).toBeInTheDocument()
  })
```

Ensure the deleted fixture includes `note_count: 5, attachment_count: 2, purge_at: <ISO>` and is named `Old`. Keep the existing restore-disabled-when-over-cap test, adapting selectors to `tr`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bunx vitest run src/settings/vaults/deleted-vaults-section.test.tsx`
Expected: FAIL — no `tr` / counts not shown.

- [ ] **Step 3: Rewrite as a table**

```tsx
import { toast } from 'sonner'
import { RotateCcw, Trash2 } from 'lucide-react'
import { useSearchParams } from 'react-router'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from '@/settings/account/section-card'
import {
  useDeletedVaults,
  useVaults,
  useRestoreVault,
  usePurgeVault,
  useBillingConfig,
  type Vault,
} from '@/api/queries'

export function DeletedVaultsSection() {
  const { data: deleted } = useDeletedVaults()
  if (!deleted || deleted.length === 0) return null

  return (
    <SettingsSectionCard
      title="Recently deleted"
      description="Deleted vaults are kept for 30 days. Restore them, or remove them permanently."
    >
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-border text-left text-xs text-muted-foreground">
            <th className="py-2 font-medium">Name</th>
            <th className="py-2 text-right font-medium">Files</th>
            <th className="py-2 text-right font-medium">Attachments</th>
            <th className="py-2 font-medium">Purges</th>
            <th className="py-2" aria-label="Actions" />
          </tr>
        </thead>
        <tbody className="divide-y divide-border">
          {deleted.map((v) => (
            <DeletedRow key={v.id} vault={v} />
          ))}
        </tbody>
      </table>
    </SettingsSectionCard>
  )
}

function DeletedRow({ vault }: { vault: Vault }) {
  const { data: active } = useVaults()
  const { data: billing } = useBillingConfig()
  const restore = useRestoreVault()
  const purge = usePurgeVault()

  const cap = billing?.vaults_cap ?? Infinity
  const activeCount = active?.length ?? 0
  const overCap = activeCount >= cap
  const purgeDate = vault.purge_at ? new Date(vault.purge_at).toLocaleDateString() : '—'

  const [searchParams] = useSearchParams()
  const highlighted = searchParams.get('highlight') === String(vault.id)

  return (
    <tr
      data-highlighted={highlighted || undefined}
      className={highlighted ? 'bg-accent/40 ring-1 ring-ring' : ''}
    >
      <td className="py-3 font-medium text-foreground">{vault.name}</td>
      <td className="py-3 text-right tabular-nums text-muted-foreground">{vault.note_count ?? 0}</td>
      <td className="py-3 text-right tabular-nums text-muted-foreground">{vault.attachment_count ?? 0}</td>
      <td className="py-3 text-muted-foreground">{purgeDate}</td>
      <td className="py-3">
        <span className="flex items-center justify-end gap-1">
          <Button
            variant="outline"
            size="sm"
            disabled={overCap || restore.isPending}
            title={
              overCap
                ? 'Restoring would exceed your vault limit. Upgrade or delete another vault first.'
                : undefined
            }
            onClick={() =>
              restore.mutate(vault.id, {
                onSuccess: () => toast.success('Vault restored'),
                onError: () => toast.error('Could not restore (vault limit reached?)'),
              })
            }
          >
            <RotateCcw />
            Restore
          </Button>
          <Button
            variant="destructive"
            size="icon-sm"
            title={`Permanently delete ${vault.name}`}
            aria-label={`Permanently delete ${vault.name}`}
            disabled={purge.isPending}
            onClick={() => {
              if (window.confirm(`Permanently delete "${vault.name}"? This cannot be undone.`)) {
                purge.mutate(vault.id, {
                  onSuccess: () => toast.success('Vault permanently deleted'),
                  onError: () => toast.error('Could not delete'),
                })
              }
            }}
          >
            <Trash2 />
          </Button>
        </span>
      </td>
    </tr>
  )
}
```

> Use `size="icon"` if `icon-sm` is absent. Keep `RotateCcw` text on Restore so the existing "Restore" label assertions still match.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend/frontend && bunx vitest run src/settings/vaults/deleted-vaults-section.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/settings/vaults/deleted-vaults-section.tsx frontend/src/settings/vaults/deleted-vaults-section.test.tsx
git commit -m "feat: render trash as a table with counts + purge date"
```

---

## Task 8: Version bump + full verification

**Files:**
- Modify: `mix.exs:7` (version)

- [ ] **Step 1: Bump version**

In `mix.exs`, bump `version:` by one patch (e.g. `0.5.247` → `0.5.248`). Check the current value first; if main moved, bump from the latest.

- [ ] **Step 2: Run the full frontend suite + typecheck**

Run: `cd backend/frontend && bunx tsc --noEmit && bunx vitest run`
Expected: PASS.

- [ ] **Step 3: Run backend format + the touched test files**

Run:
```bash
cd backend && mix format && mix test test/engram/vaults_test.exs test/engram_web/controllers/vaults_controller_test.exs
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add mix.exs
git commit -m "chore: bump version for vault settings refinements"
```

---

## Self-Review Checklist (controller covered all call sites?)

After Task 2, confirm `grep -n "vault_json(" lib/engram_web/controllers/vaults_controller.ex` shows every call passing a counts map (none passing `user`). A missed site is a compile error (the `user`-arity clause no longer exists) — that's the safety net.
