# Attachment Actions + Rename Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn on delete / rename / move for attachment rows in the web file tree (single + batch), backed by UUID-keyed S3 storage and a durable old-path tombstone so a move converges on every device with no duplicate or resurrection.

**Architecture:** Decouple the S3 object key from the mutable vault path (key by row UUID). A move/rename becomes pure metadata: repoint the live row's encrypted path + insert a soft-deleted tombstone at the old path, both stamped with one per-vault `seq` in a single transaction. The tombstone surfaces `{old, deleted:true}` through the *existing* `/attachments/changes` poll AND the new seq-cursor pull; the plugin already trashes on `deleted` and writes on upsert, so convergence needs near-zero plugin code. Real-time parity reuses the existing `note_changed` socket event with `kind:"attachment"` (the plugin already dispatches by kind).

**Tech Stack:** Elixir/Phoenix (backend), React + TanStack Query + TypeScript (frontend), TypeScript Obsidian plugin, ExUnit / bun test / Jest, headless-Obsidian e2e.

---

## Re-scope note (READ FIRST — the spec is partly OBE)

The design spec (`docs/superpowers/specs/2026-06-16-attachment-actions-and-rename-convergence-design.md`) was written **before** the sync-cursor-pull detour merged to `main` (PRs #622 change-log backbone, #628 cursor-pull). That detour changed the convergence substrate under the spec. Verified current state of `main`:

- **Spec PR2 (notes/folders rename tombstone) — half shipped.** `Notes.rename_folder/4` already inserts old-path tombstones, same-seq, in one txn (`notes.ex` ~2265, the `#614` fix). **`Notes.rename_note/4` (single) does NOT** — it repoints in place and only broadcasts an *ephemeral* socket delete (`notes.ex:696`). An offline client reconnecting via poll/cursor sees only `new_path` → **duplicate/resurrection**. That single-note gap is the only PR2 remainder → **Task 12** (own small PR).
- **Plugin already converges attachments.** It polls `/attachments/changes` (returns `deleted:true` rows), trashes on delete (`sync.ts` ~2024 `applyAttachmentChange`), writes blob on upsert, echo-suppresses via FNV-1a `syncState`. `channel.ts` dispatches `note_changed` by `kind:"attachment"`. So a move that emits **tombstone(old) + repoint(new)** converges through existing machinery. The spec's separate `attachment_changed` socket event is **dropped** — we reuse `note_changed` with `kind:"attachment"`.
- **Backend attachments do zero broadcasts today**, and `delete_external` recomputes `Storage.key(path)` (a latent bug — reads already prefer `storage_key`). These are the real backend gaps.

**Net:** PR1 = attachments (re-keying + move + endpoints + frontend + e2e). PR2 = single-note `rename_note` tombstone only. Plugin code is verify-and-e2e, likely zero source changes.

---

## Task 0: Rebase the branch onto current `main` (build prep, not a code task)

**Why:** Branch `feat/attachment-actions-and-rename-convergence` is 7 commits behind `main` and predates the cursor-pull merges. All code references below assume current `main` (`Attachments.list_changes_by_seq/4`, `Note` seq stamping, `attachments.version`/`seq` columns). Build on stale base and the new helpers won't exist.

- [ ] **Step 1: Rebase**

```bash
cd /home/open-claw/documents/code-projects/engram/.worktrees/feat-attachment-actions
git fetch origin
git rebase origin/main
```

Expected: clean rebase (the branch holds only the spec doc + this plan; no code overlap with main).

- [ ] **Step 2: Baseline tests green before any change**

```bash
mix test test/engram/attachments_test.exs test/engram/attachments_seq_feed_test.exs
```

Expected: PASS. If red on a fresh rebase, STOP and surface — do not build on a red baseline.

---

## File Structure

**Backend (`engram`):**
- Modify `lib/engram/storage.ex` — add `object_key/3` (UUID-keyed builder).
- Modify `lib/engram/attachments.ex` — `prepare_upload` keys by UUID; `delete_external` deletes by `storage_key` column; add `move_attachment/4`, `batch_move/4`, `batch_delete/3`, a `broadcast_attachment/5` helper.
- Modify `lib/engram_web/controllers/attachments_controller.ex` — add `rename/2`, `batch_move/2`, `batch_delete/2` actions (billing-gated).
- Modify `lib/engram_web/router.ex` — add the three routes (batch ops under the `IdempotencyKey` pipeline).
- Modify `lib/engram/notes.ex` — Task 12 only: `rename_note` inserts an old-path tombstone.

**Frontend (`frontend/`):**
- Modify `src/api/queries.ts` — add `useRenameAttachment`, `useBatchMoveAttachments`, `useBatchDeleteAttachments`.
- Modify `src/viewer/tree-actions/action-list.ts` — add `ATTACHMENT_ACTIONS` + handle the `attachment` kind.
- Modify `src/viewer/tree/tree-row.tsx` — un-suppress context-menu / long-press on attachment rows.
- Modify `src/viewer/folder-tree.tsx` — thread the `attachment` kind through `onRenameCommit`, `onMove`, `rowsFor`, `partition`, `commitDelete`, `kindOf`, `titleForItem`.

**Plugin (`engram-obsidian-sync`):** verify-only; e2e in the backend `e2e/` suite.

**Convention reminders:** composite-PK / `timestamptz` / `bigint` migration conventions (none needed here — no schema change). One `mix.exs` bump per engram PR; one plugin `manifest.json` bump per plugin PR (only if plugin source changes). Run `lint:obsidian` / `lint:css` / biome locally before pushing frontend.

---

# PR 1 — Attachments (S3 re-keying + move + endpoints + frontend + e2e)

## Task 1: `Storage.object_key/3` — UUID-keyed object key builder

**Files:**
- Modify: `lib/engram/storage.ex` (after `key/3`, ~line 86)
- Test: `test/engram/storage_test.exs` (create if absent)

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/storage_test.exs
defmodule Engram.StorageTest do
  use ExUnit.Case, async: true
  alias Engram.Storage

  describe "object_key/3" do
    test "keys by uuid under an objects/ namespace, independent of vault path" do
      uid = "11111111-1111-1111-1111-111111111111"
      vid = "22222222-2222-2222-2222-222222222222"
      att = "33333333-3333-3333-3333-333333333333"
      assert Storage.object_key(uid, vid, att) == "#{uid}/#{vid}/objects/#{att}"
    end

    test "two different uuids never collide even for the same future path" do
      uid = "u"; vid = "v"
      refute Storage.object_key(uid, vid, "a") == Storage.object_key(uid, vid, "b")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/storage_test.exs`
Expected: FAIL — `function Engram.Storage.object_key/3 is undefined`.

- [ ] **Step 3: Implement**

In `lib/engram/storage.ex`, immediately after the existing `key/3` (ends ~line 86):

```elixir
  @doc """
  Build a storage key from the immutable attachment row UUID. Decoupled from
  the mutable vault path so move/rename never relocates the blob and a new
  upload to a vacated path computes a fresh key (no clobber). New uploads use
  this; legacy rows keep their path-derived `storage_key` column value.
  """
  def object_key(user_id, vault_id, att_id)
      when is_binary(user_id) and is_binary(vault_id) and is_binary(att_id) and att_id != "" do
    "#{user_id}/#{vault_id}/objects/#{att_id}"
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/storage_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/storage.ex test/engram/storage_test.exs
git commit -m "feat(storage): uuid-keyed object_key builder for attachments"
```

---

## Task 2: Key new uploads by UUID + delete by stored `storage_key` column

**Files:**
- Modify: `lib/engram/attachments.ex` — `prepare_upload/8` (line 493) and `delete_external` (line 281) + `delete_attachment/3` (line 250)
- Test: `test/engram/attachments_test.exs`

**Context:** `att_id` is already pre-minted in `upsert_attachment/3` (`attachments.ex:46`, `Ecto.UUID.generate()`) and threaded into `prepare_upload`. `storage_key` is always persisted (even legacy rows), so delete-by-column is correct for both.

- [ ] **Step 1: Write the failing tests**

```elixir
# add to test/engram/attachments_test.exs (inside the existing describe or a new one)
test "new upload keys storage by uuid, not by path", %{user: user, vault: vault} do
  {:ok, att} = Attachments.upsert_attachment(user, vault, %{
    "path" => "img/cat.png", "content_base64" => Base.encode64("PNGDATA"),
    "mime_type" => "image/png", "mtime" => 1.0
  })
  assert att.storage_key =~ ~r{/objects/#{att.id}$}
  refute att.storage_key =~ "img/cat.png"
end

test "a new upload to a vacated path does NOT clobber a different blob", %{user: user, vault: vault} do
  {:ok, a} = Attachments.upsert_attachment(user, vault, %{
    "path" => "p/x.png", "content_base64" => Base.encode64("AAA"),
    "mime_type" => "image/png", "mtime" => 1.0
  })
  :ok = Attachments.delete_attachment(user, vault, "p/x.png")
  {:ok, b} = Attachments.upsert_attachment(user, vault, %{
    "path" => "p/x.png", "content_base64" => Base.encode64("BBB"),
    "mime_type" => "image/png", "mtime" => 2.0
  })
  refute a.storage_key == b.storage_key
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/engram/attachments_test.exs -k "uuid"`
Expected: FAIL — `storage_key` still path-derived (`Storage.key`).

- [ ] **Step 3: Implement — `prepare_upload` keys by uuid**

In `lib/engram/attachments.ex`, `prepare_upload/8`, change line 493:

```elixir
    # was: key = Storage.key(user.id, vault.id, path)
    key = Storage.object_key(user.id, vault.id, att_id)
```

- [ ] **Step 4: Implement — delete by the stored `storage_key` column**

Replace `delete_external/3` (lines 281–298) and its call site so it deletes the column, not a recomputed path key. First change `delete_attachment/3` to load the row's `storage_key` and pass it; then make `delete_external/1` take the key.

In `delete_attachment/3` (lines 250–279), replace the `Repo.with_tenant` block + the `delete_external` call:

```elixir
        storage_key =
          Repo.with_tenant(user.id, fn ->
            seq = Engram.Vaults.next_seq!(vault.id)

            {_, returned} =
              from(a in Attachment,
                where:
                  a.path_hmac == ^path_hmac and a.user_id == ^user.id and
                    a.vault_id == ^vault.id and is_nil(a.deleted_at),
                select: a.storage_key
              )
              |> Repo.update_all(set: [deleted_at: now, updated_at: now, seq: seq])

            List.first(returned || [])
          end)
          |> unwrap_tenant()

        # Best-effort blob cleanup — row is already soft-deleted so safe to retry.
        if is_binary(storage_key), do: delete_external(storage_key)
```

Replace `delete_external/3` with `delete_external/1`:

```elixir
  defp delete_external(storage_key) when is_binary(storage_key) do
    case Storage.adapter().delete(storage_key) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning("Failed to delete blob (row already soft-deleted)",
          storage_key: storage_key,
          reason: inspect(reason)
        )

        :ok
    end
  end
```

> Note: `update_all` with `select:` returns `{count, rows}` where `rows` is a list of the selected field — used here to recover the deleted row's `storage_key` without a second query. If `unwrap_tenant` wraps differently in this module, match its existing pattern (it returns the inner value for the other callers).

- [ ] **Step 5: Run tests to verify pass**

Run: `mix test test/engram/attachments_test.exs`
Expected: PASS (existing delete tests + the two new ones).

- [ ] **Step 6: Commit**

```bash
git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(attachments): key blobs by uuid; delete by storage_key column"
```

---

## Task 3: `Attachments.move_attachment/4` — repoint live row + old-path tombstone

**Files:**
- Modify: `lib/engram/attachments.ex` — add public `move_attachment/4` + a private tombstone builder
- Test: `test/engram/attachments_test.exs`

**Mirrors:** `Notes.rename_folder/4` tombstone insert (`notes.ex` ~2265) and `prepare_upload` path-encrypt (`Crypto.aad_for_row(:attachments, :path, att_id)` + `Envelope.encrypt`).

- [ ] **Step 1: Write the failing tests**

```elixir
describe "move_attachment/4" do
  setup %{user: user, vault: vault} do
    {:ok, att} = Attachments.upsert_attachment(user, vault, %{
      "path" => "old/a.png", "content_base64" => Base.encode64("DATA"),
      "mime_type" => "image/png", "mtime" => 1.0
    })
    %{att: att}
  end

  test "repoints the live row, blob/storage_key untouched", %{user: user, vault: vault, att: att} do
    {:ok, moved} = Attachments.move_attachment(user, vault, "old/a.png", "new/b.png")
    assert moved.id == att.id
    assert moved.path == "new/b.png"
    assert moved.storage_key == att.storage_key
    {:ok, fetched} = Attachments.get_attachment(user, vault, "new/b.png")
    assert fetched.content == "DATA"
  end

  test "emits a soft-deleted tombstone at the old path", %{user: user, vault: vault} do
    {:ok, _} = Attachments.move_attachment(user, vault, "old/a.png", "new/b.png")
    {:ok, %{changes: changes}} = Attachments.list_changes_by_seq(user, vault, 0)
    assert Enum.any?(changes, &(&1.path == "old/a.png" and &1.deleted))
    assert Enum.any?(changes, &(&1.path == "new/b.png" and not &1.deleted))
  end

  test "conflict on occupied target → :conflict", %{user: user, vault: vault} do
    {:ok, _} = Attachments.upsert_attachment(user, vault, %{
      "path" => "new/b.png", "content_base64" => Base.encode64("X"),
      "mime_type" => "image/png", "mtime" => 1.0
    })
    assert {:error, :conflict} = Attachments.move_attachment(user, vault, "old/a.png", "new/b.png")
  end

  test "no-op move (old == new) is idempotent, no tombstone", %{user: user, vault: vault} do
    {:ok, _} = Attachments.move_attachment(user, vault, "old/a.png", "old/a.png")
    {:ok, %{changes: changes}} = Attachments.list_changes_by_seq(user, vault, 0)
    refute Enum.any?(changes, &(&1.deleted))
  end

  test "missing source → :not_found", %{user: user, vault: vault} do
    assert {:error, :not_found} = Attachments.move_attachment(user, vault, "nope.png", "x.png")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/engram/attachments_test.exs -k "move_attachment"`
Expected: FAIL — `move_attachment/4` undefined.

- [ ] **Step 3: Implement `move_attachment/4`**

Add to `lib/engram/attachments.ex` (public function, near `delete_attachment`):

```elixir
  @doc """
  Moves/renames an attachment by path. One transaction under the per-vault seq:
  repoint the live row (id stable, path re-encrypted under its unchanged
  id-AAD, storage_key + blob untouched) and insert a soft-deleted tombstone at
  the old path so poll/cursor clients converge (trash old, write new). Mirrors
  `Engram.Notes.rename_folder/4`'s tombstone discipline (#614).
  """
  @spec move_attachment(map(), map(), String.t(), String.t()) ::
          {:ok, Attachment.t()} | {:error, :conflict | :not_found | term()}
  def move_attachment(user, vault, old_path, new_path) do
    old_path = PathSanitizer.sanitize(old_path)
    new_path = PathSanitizer.sanitize(new_path)
    user = fresh_user(user)
    now = DateTime.utc_now(:second)

    with {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, dek} <- Crypto.get_dek(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      old_hmac = Crypto.hmac_field(filter_key, old_path)
      new_hmac = Crypto.hmac_field(filter_key, new_path)

      Repo.transaction(fn ->
        Repo.with_tenant(user.id, fn ->
          live = Repo.one(live_by_hmac_query(user, vault, old_hmac))

          cond do
            is_nil(live) ->
              Repo.rollback(:not_found)

            old_path == new_path ->
              {:ok, att} = Crypto.maybe_decrypt_attachment_fields(live, user)
              att

            Repo.one(live_by_hmac_query(user, vault, new_hmac)) ->
              Repo.rollback(:conflict)

            true ->
              seq = Engram.Vaults.next_seq!(vault.id)

              # Repoint the live row: re-encrypt path under the SAME id-AAD.
              path_aad = Crypto.aad_for_row(:attachments, :path, live.id)
              {path_ct, path_n} = Envelope.encrypt(new_path, dek, path_aad)

              {1, _} =
                from(a in Attachment, where: a.id == ^live.id)
                |> Repo.update_all(
                  set: [
                    path_ciphertext: path_ct,
                    path_nonce: path_n,
                    path_hmac: new_hmac,
                    updated_at: now,
                    seq: seq
                  ]
                )

              # Insert the old-path tombstone (fresh uuid, own id-AAD).
              Repo.insert!(tombstone_changeset(user, vault, dek, old_path, old_hmac, live, seq, now))

              %{live | path: new_path, path_ciphertext: path_ct, path_nonce: path_n,
                       path_hmac: new_hmac, updated_at: now, seq: seq}
          end
        end)
        |> unwrap_tenant()
      end)
      |> case do
        {:ok, %Attachment{} = att} ->
          if old_path != new_path do
            broadcast_attachment(user.id, vault.id, "delete", old_path, att)
            broadcast_attachment(user.id, vault.id, "upsert", new_path, att)
          end

          {:ok, att}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp live_by_hmac_query(user, vault, hmac) do
    from(a in Attachment,
      where:
        a.path_hmac == ^hmac and a.user_id == ^user.id and
          a.vault_id == ^vault.id and is_nil(a.deleted_at)
    )
  end

  # Soft-deleted full-row insert at the vacated path. storage_key=nil (no blob),
  # content_hash carried from the live row (satisfies the changeset; value
  # irrelevant — row is deleted). Path encrypted under the tombstone's OWN
  # id-AAD so reads of the (never-served) row stay AAD-consistent.
  defp tombstone_changeset(user, vault, dek, old_path, old_hmac, live, seq, now) do
    tomb_id = Ecto.UUID.generate()
    path_aad = Crypto.aad_for_row(:attachments, :path, tomb_id)
    {path_ct, path_n} = Envelope.encrypt(old_path, dek, path_aad)

    Attachment.changeset(%Attachment{id: tomb_id}, %{
      path_ciphertext: path_ct,
      path_nonce: path_n,
      path_hmac: old_hmac,
      content_hash: live.content_hash,
      mime_type: live.mime_type,
      size_bytes: live.size_bytes,
      mtime: live.mtime,
      user_id: user.id,
      vault_id: vault.id,
      storage_key: nil,
      deleted_at: now,
      updated_at: now,
      seq: seq,
      version: 1,
      encryption_version: 1,
      dek_version: Crypto.row_version_aad_bound(),
      content_nonce: nil
    })
  end
```

> Verify against the schema: `Attachment.changeset/2` must cast `created_at`/`inserted_at` automatically (it uses `timestamps(inserted_at: :created_at)`). If `Repo.insert!` complains about a missing `created_at`, set it explicitly in the attrs map (`created_at: now`). The fields cast list in `attachment.ex` already includes every key used above.

- [ ] **Step 4: Run tests to verify pass**

Run: `mix test test/engram/attachments_test.exs -k "move_attachment"`
Expected: PASS (5 tests). The broadcast tests in Task 5 will assert the socket payloads.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(attachments): move_attachment — repoint + old-path tombstone"
```

---

## Task 4: Batch move + batch delete (context functions)

**Files:**
- Modify: `lib/engram/attachments.ex` — add `batch_move/4`, `batch_delete/3`
- Test: `test/engram/attachments_test.exs`

**Shape:** attachments are path-keyed (no folder rows), so batch-move takes `paths` + a `target_folder` *string*; each item's new path = `Path.join(target_folder, basename)` (or just basename at root). All-or-nothing via `Repo.transaction` + `Enum.reduce_while`, mirroring `Notes.batch_move_notes/4` (`notes.ex:911`).

- [ ] **Step 1: Write the failing tests**

```elixir
describe "batch_move/4 + batch_delete/3" do
  setup %{user: user, vault: vault} do
    for p <- ["a.png", "b.png"] do
      {:ok, _} = Attachments.upsert_attachment(user, vault, %{
        "path" => p, "content_base64" => Base.encode64(p),
        "mime_type" => "image/png", "mtime" => 1.0
      })
    end
    :ok
  end

  test "batch_move relocates each into the target folder", %{user: user, vault: vault} do
    {:ok, %{moved: 2}} = Attachments.batch_move(user, vault, ["a.png", "b.png"], "img")
    {:ok, _} = Attachments.get_attachment(user, vault, "img/a.png")
    {:ok, _} = Attachments.get_attachment(user, vault, "img/b.png")
  end

  test "batch_move to root keeps basenames", %{user: user, vault: vault} do
    {:ok, _} = Attachments.batch_move(user, vault, ["a.png"], "img")
    {:ok, %{moved: 1}} = Attachments.batch_move(user, vault, ["img/a.png"], "")
    {:ok, _} = Attachments.get_attachment(user, vault, "a.png")
  end

  test "batch_move rolls back on conflict", %{user: user, vault: vault} do
    {:ok, _} = Attachments.upsert_attachment(user, vault, %{
      "path" => "img/a.png", "content_base64" => Base.encode64("X"),
      "mime_type" => "image/png", "mtime" => 1.0
    })
    assert {:error, {:conflict, "a.png"}} = Attachments.batch_move(user, vault, ["a.png"], "img")
    # b.png untouched, a.png still at root
    {:ok, _} = Attachments.get_attachment(user, vault, "a.png")
  end

  test "batch_delete soft-deletes each", %{user: user, vault: vault} do
    {:ok, %{deleted: 2}} = Attachments.batch_delete(user, vault, ["a.png", "b.png"])
    {:ok, nil} = Attachments.get_attachment(user, vault, "a.png")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/engram/attachments_test.exs -k "batch_move"`
Expected: FAIL — undefined functions.

- [ ] **Step 3: Implement**

```elixir
  @doc "Moves each attachment into `target_folder` (\"\" = root). All-or-nothing."
  @spec batch_move(map(), map(), [String.t()], String.t()) ::
          {:ok, %{moved: non_neg_integer()}} | {:error, {atom(), String.t()} | term()}
  def batch_move(_user, _vault, [], _target_folder), do: {:ok, %{moved: 0}}

  def batch_move(user, vault, paths, target_folder) when is_list(paths) and is_binary(target_folder) do
    Repo.transaction(fn ->
      Enum.reduce_while(paths, %{moved: 0}, fn old_path, acc ->
        base = Path.basename(old_path)
        new_path = if target_folder == "", do: base, else: Path.join(target_folder, base)

        case move_attachment(user, vault, old_path, new_path) do
          {:ok, _} -> {:cont, Map.update!(acc, :moved, &(&1 + 1))}
          {:error, :conflict} -> {:halt, {:rollback, {:conflict, old_path}}}
          {:error, :not_found} -> {:halt, {:rollback, {:not_found, old_path}}}
          {:error, reason} -> {:halt, {:rollback, reason}}
        end
      end)
      |> case do
        {:rollback, reason} -> Repo.rollback(reason)
        acc -> acc
      end
    end)
  end

  @doc "Soft-deletes each attachment by path. All-or-nothing (delete is idempotent)."
  @spec batch_delete(map(), map(), [String.t()]) :: {:ok, %{deleted: non_neg_integer()}}
  def batch_delete(_user, _vault, []), do: {:ok, %{deleted: 0}}

  def batch_delete(user, vault, paths) when is_list(paths) do
    Enum.each(paths, fn p -> :ok = delete_attachment(user, vault, p) end)
    {:ok, %{deleted: length(paths)}}
  end
```

> `move_attachment` runs its own `Repo.transaction`; nesting inside `batch_move`'s transaction is fine in Ecto (savepoints/joins the outer txn). The per-item broadcasts in `move_attachment` fire on each success — acceptable (mirrors per-note rename broadcasts). If you prefer one digest, defer broadcasts; not required.

- [ ] **Step 4: Run tests to verify pass**

Run: `mix test test/engram/attachments_test.exs -k "batch"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(attachments): batch_move + batch_delete context fns"
```

---

## Task 5: Socket broadcast — `note_changed` with `kind:"attachment"`

**Files:**
- Modify: `lib/engram/attachments.ex` — add `broadcast_attachment/5` (already called in Task 3)
- Test: `test/engram/attachments_test.exs`

**Why reuse `note_changed`:** the plugin's `channel.ts` already reads `payload.kind` and routes `kind:"attachment"` events to `applyAttachmentChange`. A dedicated `attachment_changed` event would need new plugin code for zero benefit. Payload mirrors the spec: `{op, path, mime_type, size_bytes, mtime}` plus the `kind` discriminator and `event_type` the plugin expects.

- [ ] **Step 1: Write the failing test**

```elixir
test "move broadcasts delete(old) + upsert(new) with kind=attachment", %{user: user, vault: vault} do
  {:ok, att} = Attachments.upsert_attachment(user, vault, %{
    "path" => "old/a.png", "content_base64" => Base.encode64("D"),
    "mime_type" => "image/png", "mtime" => 1.0
  })
  topic = "sync:#{user.id}:#{vault.id}"
  EngramWeb.Endpoint.subscribe(topic)

  {:ok, _} = Attachments.move_attachment(user, vault, "old/a.png", "new/b.png")

  assert_receive %Phoenix.Socket.Broadcast{
    event: "note_changed",
    payload: %{"event_type" => "delete", "kind" => "attachment", "path" => "old/a.png"}
  }
  assert_receive %Phoenix.Socket.Broadcast{
    event: "note_changed",
    payload: %{"event_type" => "upsert", "kind" => "attachment", "path" => "new/b.png",
               "mime_type" => "image/png"}
  }
  _ = att
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/engram/attachments_test.exs -k "broadcasts delete"`
Expected: FAIL — `broadcast_attachment/5` undefined (compile error) or no message received.

- [ ] **Step 3: Implement**

```elixir
  # Real-time parity: reuse the existing `note_changed` socket event the plugin
  # already dispatches by `kind`. A move fires delete(old) + upsert(new), like
  # Notes.rename. Receive-only on the plugin — it still pushes over HTTP.
  defp broadcast_attachment(user_id, vault_id, event_type, path, %Attachment{} = att) do
    payload = %{
      "event_type" => event_type,
      "kind" => "attachment",
      "path" => path,
      "vault_id" => vault_id,
      "mime_type" => att.mime_type,
      "size_bytes" => att.size_bytes,
      "mtime" => att.mtime
    }

    _ = EngramWeb.Endpoint.broadcast("sync:#{user_id}:#{vault_id}", "note_changed", payload)
    :ok
  end
```

Also emit on single delete: in `delete_attachment/3`, after the best-effort blob cleanup, add a delete broadcast (load needs only the path — mime/size unknown post-delete, send what we have):

```elixir
        _ = EngramWeb.Endpoint.broadcast("sync:#{user.id}:#{vault.id}", "note_changed", %{
          "event_type" => "delete", "kind" => "attachment", "path" => path, "vault_id" => vault.id
        })
```

- [ ] **Step 4: Run test to verify pass**

Run: `mix test test/engram/attachments_test.exs -k "broadcasts"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(attachments): real-time note_changed broadcast (kind=attachment)"
```

---

## Task 6: Controller actions + routes (billing-gated, idempotent batch)

**Files:**
- Modify: `lib/engram_web/controllers/attachments_controller.ex` — add `rename/2`, `batch_move/2`, `batch_delete/2`
- Modify: `lib/engram_web/router.ex` — add routes (batch under `IdempotencyKey`)
- Test: `test/engram_web/controllers/attachments_controller_test.exs`

**Mirrors:** `NotesController.rename/2` (`notes_controller.ex:114`), `batch_move/2` (`:389`), `batch_delete/2` (`:357`), and the `Billing.check_feature(user, :attachments_enabled)` gate (`attachments_controller.ex:15`). Batch endpoints read `conn.assigns.idempotency_key` and call `Engram.Idempotency.remember/2`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/engram_web/controllers/attachments_controller_test.exs (add to existing)
test "POST /attachments/rename moves and returns new path", %{conn: conn, user: user, vault: vault} do
  {:ok, _} = Attachments.upsert_attachment(user, vault, %{
    "path" => "old/a.png", "content_base64" => Base.encode64("D"),
    "mime_type" => "image/png", "mtime" => 1.0
  })
  conn = post(authed(conn, user, vault), "/api/attachments/rename",
    %{"old_path" => "old/a.png", "new_path" => "new/b.png"})
  assert json_response(conn, 200)["renamed"] == true
end

test "POST /attachments/rename conflict → 409", %{conn: conn, user: user, vault: vault} do
  for p <- ["a.png", "b.png"], do:
    {:ok, _} = Attachments.upsert_attachment(user, vault, %{
      "path" => p, "content_base64" => Base.encode64(p), "mime_type" => "image/png", "mtime" => 1.0})
  conn = post(authed(conn, user, vault), "/api/attachments/rename",
    %{"old_path" => "a.png", "new_path" => "b.png"})
  assert json_response(conn, 409)["error"] == "conflict"
end

test "POST /attachments/batch-move requires idempotency key", %{conn: conn, user: user, vault: vault} do
  conn = post(authed(conn, user, vault), "/api/attachments/batch-move",
    %{"paths" => ["a.png"], "target_folder" => "img"})
  assert json_response(conn, 400)["error"] == "missing_idempotency_key"
end
```

> Use whatever `authed/3` test helper the existing attachments controller test uses (`authed_api_conn/1` was extracted in #621 — match the file's current pattern).

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/engram_web/controllers/attachments_controller_test.exs -k "rename"`
Expected: FAIL — route not found (404/no_route).

- [ ] **Step 3: Implement controller actions**

In `lib/engram_web/controllers/attachments_controller.ex`:

```elixir
  def rename(conn, %{"old_path" => old_path, "new_path" => new_path}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with :ok <- Billing.check_feature(user, :attachments_enabled),
         {:ok, _att} <- Attachments.move_attachment(user, vault, old_path, new_path) do
      json(conn, %{renamed: true, old_path: old_path, new_path: new_path})
    else
      {:error, :feature_not_available} ->
        EngramWeb.LimitResponse.halt(conn, "attachments_disabled", :attachments_enabled, false, nil)

      {:error, :conflict} ->
        conn |> put_status(409) |> json(%{error: "conflict"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  def batch_move(conn, %{"paths" => paths, "target_folder" => target}) when is_list(paths) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case Attachments.batch_move(user, vault, paths, target) do
      {:ok, %{moved: n}} ->
        body = %{moved: n}
        Engram.Idempotency.remember(conn.assigns.idempotency_key, %{status: 200, body: body})
        json(conn, body)

      {:error, {:conflict, p}} ->
        conn |> put_status(409) |> json(%{error: "conflict", item_path: p})

      {:error, {:not_found, p}} ->
        conn |> put_status(404) |> json(%{error: "not_found", item_path: p})

      {:error, _} ->
        conn |> put_status(500) |> json(%{error: "internal"})
    end
  end

  def batch_delete(conn, %{"paths" => paths}) when is_list(paths) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, %{deleted: n}} = Attachments.batch_delete(user, vault, paths)
    body = %{deleted: n}
    Engram.Idempotency.remember(conn.assigns.idempotency_key, %{status: 200, body: body})
    json(conn, body)
  end
```

- [ ] **Step 4: Implement routes**

In `lib/engram_web/router.ex`, attachments block (after line 356, the `/attachments/changes` route — keep `rename` BEFORE the `/attachments/*path` catch-all):

```elixir
    post "/attachments/rename", AttachmentsController, :rename
```

And add the two batch routes to the existing `IdempotencyKey` scope (lines 326–334, beside the notes batch routes):

```elixir
    post "/attachments/batch-move", AttachmentsController, :batch_move
    post "/attachments/batch-delete", AttachmentsController, :batch_delete
```

- [ ] **Step 5: Run tests to verify pass**

Run: `mix test test/engram_web/controllers/attachments_controller_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/engram_web/controllers/attachments_controller.ex lib/engram_web/router.ex test/engram_web/controllers/attachments_controller_test.exs
git commit -m "feat(attachments): rename + batch-move + batch-delete endpoints"
```

---

## Task 7: Frontend mutation hooks

**Files:**
- Modify: `frontend/src/api/queries.ts` — add three hooks
- Test: `frontend/src/api/queries.test.ts` (or the existing queries test file — match location)

**Mirrors:** `useRenameNote` (`queries.ts:1140`), `useBatchMoveNotes` (`:1779`), `useBatchDeleteNotes` (`:1721`), and `idempotencyHeaders()` (`:1707`). `api.post` signature: `post<T>(path, body?, { headers })` (`client.ts:85`).

- [ ] **Step 1: Write the failing test**

```ts
// in the existing queries test file
import { useRenameAttachment } from './queries'
// (follow the file's existing render-hook + mock-api pattern; assert the
// mutationFn POSTs '/attachments/rename' with {old_path,new_path} and that
// onSettled invalidates ['folders', vaultId] and ['attachments', vaultId])
```

> If `queries.ts` has no unit test harness, skip the unit test and rely on the e2e + manual smoke (Task 11). Note that in the plan's progress comment so it isn't a silent gap.

- [ ] **Step 2: Implement the hooks**

Append to `frontend/src/api/queries.ts`:

```ts
export function useRenameAttachment() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()
  return useMutation<
    { renamed: boolean; old_path: string; new_path: string },
    ApiError,
    { old_path: string; new_path: string }
  >({
    mutationFn: (vars) =>
      api.post<{ renamed: boolean; old_path: string; new_path: string }>('/attachments/rename', vars),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['folders', vaultId] })
      qc.invalidateQueries({ queryKey: ['folderNotes', vaultId] })
      qc.invalidateQueries({ queryKey: ['attachments', vaultId] })
    },
  })
}

export function useBatchMoveAttachments() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()
  return useMutation<{ moved: number }, ApiError, { paths: string[]; target_folder: string }>({
    mutationFn: ({ paths, target_folder }) =>
      api.post<{ moved: number }>('/attachments/batch-move', { paths, target_folder }, idempotencyHeaders()),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['folders', vaultId] })
      qc.invalidateQueries({ queryKey: ['folderNotes', vaultId] })
      qc.invalidateQueries({ queryKey: ['attachments', vaultId] })
    },
  })
}

export function useBatchDeleteAttachments() {
  const qc = useQueryClient()
  const vaultId = useActiveVaultId()
  return useMutation<{ deleted: number }, ApiError, { paths: string[] }>({
    mutationFn: ({ paths }) =>
      api.post<{ deleted: number }>('/attachments/batch-delete', { paths }, idempotencyHeaders()),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['folders', vaultId] })
      qc.invalidateQueries({ queryKey: ['folderNotes', vaultId] })
      qc.invalidateQueries({ queryKey: ['attachments', vaultId] })
    },
  })
}
```

> Confirm the attachments query key (`['attachments', vaultId]`) matches the Phase-1 list query key in `queries.ts` — adjust if it differs.

- [ ] **Step 3: Typecheck + lint**

Run: `cd frontend && bun run build && bunx biome check src/api/queries.ts`
Expected: no type errors.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/api/queries.ts
git commit -m "feat(web): attachment rename + batch move/delete mutation hooks"
```

---

## Task 8: Frontend tree wiring — un-suppress + thread the `attachment` kind

**Files:**
- Modify: `frontend/src/viewer/tree-actions/action-list.ts` — `ATTACHMENT_ACTIONS` + `actionsFor`
- Modify: `frontend/src/viewer/tree/tree-row.tsx` — un-suppress menu/long-press on attachment `<Link>`
- Modify: `frontend/src/viewer/folder-tree.tsx` — `onRenameCommit`, `onMove`, `rowsFor`, `partition`, `commitDelete`, `kindOf`, `titleForItem`

**Key facts:** `parseItemId` already returns `{kind:'attachment', path}` (`tree/types.ts:38`). Attachments are **path-keyed** (no id), so all branches thread `path`, not id. Move target stays a folder *path* string (synthetic attachment folders "just work").

- [ ] **Step 1: `action-list.ts` — attachment actions**

```ts
const ATTACHMENT_ACTIONS: readonly Action[] = [
  { id: 'rename', label: 'Rename' },
  { id: 'move', label: 'Move to…' },
  { id: 'delete', label: 'Delete', destructive: true },
]

// in actionsFor(kind): add
//   if (kind === 'attachment') return ATTACHMENT_ACTIONS
```

(Subset of `FILE_ACTIONS` — no duplicate / copy-wikilink for binaries.)

- [ ] **Step 2: `tree-row.tsx` — un-suppress (lines 93–124 attachment branch)**

Add the same affordances the note branch uses (`tree-row.tsx:138`) to the attachment `<Link>`:

```tsx
    <Link
      to={`/note/${item.id}`}
      {...instance.getProps()}
      {...longPressProps}
      onContextMenu={contextMenuHandler}
      aria-selected={instance.isSelected()}
      className={rowClass(instance)}
      style={{ paddingLeft: `${notePad}px` }}
    >
```

Ensure `longPressProps` / `contextMenuHandler` are computed for the attachment branch too (lift them above the `if (item.kind === 'attachment')` early-return, or compute per-kind). The handlers dispatch by the row's item id — `parseItemId` already yields the `attachment` kind.

- [ ] **Step 3: `folder-tree.tsx` — thread the kind**

`onRenameCommit` (lines 89–110) — add an attachment branch:

```tsx
  } else if (p.kind === 'attachment') {
    const parts = p.path.split('/')
    parts[parts.length - 1] = newName
    const new_path = parts.join('/')
    renameAttachment.mutateAsync({ old_path: p.path, new_path }).catch(() => toast.error('Rename failed'))
  }
```

`onMove` (lines 114–134) — partition attachment source paths and call the attachment batch-move with the target folder *name*:

```tsx
  const attachmentPaths = parsed.filter((x) => x.kind === 'attachment').map((x) => (x as { path: string }).path)
  const destFolder = target.kind === 'root' ? '' : (folders?.find((f) => f.id === target.id)?.name ?? '')
  if (attachmentPaths.length) batchMoveAttachments.mutate({ paths: attachmentPaths, target_folder: destFolder })
```

`partition` (lines 336–348), `commitDelete` (lines 350–357) — collect attachment paths and call `batchDeleteAttachments.mutate({ paths })`:

```tsx
function partition(itemIds: string[]) {
  const noteIds: string[] = []; const folderIds: string[] = []; const attachmentPaths: string[] = []
  for (const id of itemIds) {
    const p = parseItemId(id)
    if (p.kind === 'note') noteIds.push(p.id)
    else if (p.kind === 'folder' && !isSyntheticFolderId(p.id)) folderIds.push(p.id)
    else if (p.kind === 'attachment') attachmentPaths.push(p.path)
  }
  return { noteIds, folderIds, attachmentPaths }
}
// commitDelete: if (attachmentPaths.length) batchDeleteAttachments.mutate({ paths: attachmentPaths })
```

`rowsFor` (lines 226–246) — add an attachment case returning `[{ kind: 'file', path: p.path }]` (delete + move dialogs both take `{kind:'file', path}`).

`kindOf` (lines 258–261) — `attachment` returns `'file'` (dialogs treat attachments as files). `titleForItem` (lines 263–274) — attachment returns `p.path.split('/').pop()`.

Wire the new hooks at the top of the component:

```tsx
const renameAttachment = useRenameAttachment()
const batchMoveAttachments = useBatchMoveAttachments()
const batchDeleteAttachments = useBatchDeleteAttachments()
```

- [ ] **Step 4: Build + lint**

```bash
cd frontend && bun run build && bunx biome check src/viewer
```

Expected: no type errors. (`bun run lint:obsidian`/`lint:css` are plugin-side; run frontend biome here.)

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer
git commit -m "feat(web): enable rename/move/delete on attachment tree rows"
```

---

## Task 9: Plugin convergence — verify (likely zero source change)

**Files:** none expected. Verification only.

The plugin already: polls `/attachments/changes` and trashes `deleted` rows / writes upserts (`sync.ts` ~2024 `applyAttachmentChange`); echo-suppresses via `syncState` FNV-1a; dispatches socket `note_changed` by `kind:"attachment"` (`channel.ts` ~252, `sync.ts:1599` `handleStreamEvent`). A backend move = tombstone(old) + repoint(new) in both the poll feed and two `note_changed` broadcasts → plugin trashes old + writes new, echo-suppressed.

- [ ] **Step 1: Read and confirm**

Read `sync.ts` `applyAttachmentChange` and `handleStreamEvent`; confirm a `note_changed` event with `kind:"attachment", event_type:"delete"` reaches `trashFile` + `removeEmptyFolders`. Confirm the upsert path fetches the blob via `getAttachment(path)` and `modifyBinary`/`createBinaryFileWithFolders`, then records `syncState`.

- [ ] **Step 2: Only if a gap is found** — fix minimally in `sync.ts`/`channel.ts`, bump `manifest.json` once, open a paired plugin PR named `feat/attachment-actions-and-rename-convergence` (for `plugin_branch` e2e pairing). Otherwise no plugin PR.

- [ ] **Step 3: Note the outcome** in the PR description (e.g. "plugin converges with zero source change; verified by e2e test_NN").

---

## Task 10: E2E — web-originated attachment move converges in Obsidian

**Files:**
- Create/modify: `e2e/tests/` — a new attachment-move convergence test (follow the existing rename/move e2e shape)
- Test infra: `make e2e` (CI stack + Obsidian)

- [ ] **Step 1: Write the e2e**

Scenario: seed an attachment in vault A (push from Obsidian or upload via API) → perform a web-originated move (`POST /api/attachments/rename`) → assert in Obsidian A: file appears at new path, **no file remains at old path** (no duplicate, no resurrection after a full reconcile pull). Cover both: (a) live socket delivery, (b) offline catch-up (disconnect socket, move, reconnect → poll/cursor convergence).

- [ ] **Step 2: Run**

```bash
make ci-up && make e2e   # or the targeted test file
```

Expected: PASS — no duplicate at old path on either path.

- [ ] **Step 3: Commit**

```bash
git add e2e/tests
git commit -m "test(e2e): web attachment move converges in Obsidian (no dup)"
```

---

## Task 11: PR1 finalize

- [ ] **Step 1: Full backend suite + frontend build**

```bash
mix test
cd frontend && bun run build && bunx biome check src
```

Expected: green.

- [ ] **Step 2: Bump `mix.exs` version once** (per project rule — one bump per PR, surface collisions rather than re-bumping).

- [ ] **Step 3: Manual smoke** (per the local-browser CDP tunnel doc): right-click an attachment in the web tree → Rename / Move / Delete → confirm the tree updates and a paired Obsidian vault converges.

- [ ] **Step 4: Open PR1** (engram). Title: `feat: attachment actions (delete/rename/move) + uuid-keyed storage + tombstone convergence`. Body links the spec + this plan; notes the plugin needed zero source change (or links the paired plugin PR).

---

# PR 2 — Single-note `rename_note` tombstone (the spec PR2 remainder)

> Separate, small, high-blast-radius PR. Folder rename already emits tombstones (#614); this closes the matching single-note gap so an **offline** client converges a web/MCP-originated note rename without a duplicate.

## Task 12: `rename_note` inserts an old-path tombstone

**Files:**
- Modify: `lib/engram/notes.ex` — `do_rename_note_inner/5` (lines 715–771) + `do_rename_note/6` success arm (lines 687–699)
- Test: `test/engram/notes_seq_feed_test.exs`, `test/engram/notes_test.exs`

**Mirror:** the folder-rename tombstone insert (`notes.ex` ~2265): same-seq, in-txn, fresh-uuid soft-deleted row at the old path, path encrypted under its own id-AAD. **Must NOT** enqueue `EmbedNote` for the tombstone, and folder counts already filter `deleted_at IS NULL` (assert it holds).

- [ ] **Step 1: Write the failing test**

```elixir
# test/engram/notes_seq_feed_test.exs
test "single note rename emits an old-path tombstone in the seq feed", %{user: user, vault: vault} do
  {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
  {:ok, _} = Notes.rename_note(user, vault, "a.md", "b.md")

  {:ok, %{changes: all}} = Notes.list_changes_by_seq(user, vault, 0)
  assert Enum.any?(all, &(&1.path == "a.md" and &1.deleted))
  assert Enum.any?(all, &(&1.path == "b.md" and not &1.deleted))
end

test "rename tombstone does not resurrect: re-create at old path succeeds", %{user: user, vault: vault} do
  {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
  {:ok, _} = Notes.rename_note(user, vault, "a.md", "b.md")
  assert {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A2"})
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/engram/notes_seq_feed_test.exs -k "tombstone"`
Expected: FAIL — only `b.md` present; no `a.md` tombstone.

- [ ] **Step 3: Implement**

In `do_rename_note_inner/5`, after the `Repo.update_all` repoint (line 749) and inside the same `Repo.with_tenant` txn that `do_rename_note/6` runs, insert the old-path tombstone using the SAME `seq` already allocated at line 738. Build it from in-memory data (fresh uuid, path encrypted under its own id-AAD via `full_aad_bound_kw` or the path-only helper, `deleted_at: now`, `seq: seq`, `embed_hash: nil`). Return the renamed note unchanged. The success arm (lines 690–694) must keep enqueuing `EmbedNote` for the **renamed** note only — never for the tombstone.

> Use the exact same tombstone-row construction the folder cascade uses (`notes.ex` ~2272+) so encryption/AAD/columns stay consistent. The single-note case inserts exactly one tombstone.

- [ ] **Step 4: Run tests to verify pass**

Run: `mix test test/engram/notes_seq_feed_test.exs test/engram/notes_test.exs`
Expected: PASS, including the existing rename + folder-count tests (tombstones invisible to count queries).

- [ ] **Step 5: E2E — offline single-note rename converges (no dup)**

Add/extend an e2e mirroring Task 10 but for a note rename with the socket disconnected during the rename, then reconnect.

- [ ] **Step 6: Bump `mix.exs` once + commit + open PR2**

```bash
git add lib/engram/notes.ex test/engram
git commit -m "fix(sync): rename_note emits old-path tombstone (offline convergence)"
```

PR2 title: `fix(sync): single-note rename tombstone — close offline resurrection gap`.

---

## Self-Review (run after writing — done)

- **Spec coverage:** S3 re-keying (T1–T2) ✓; move + tombstone (T3) ✓; batch (T4) ✓; sockets (T5, reused `note_changed`) ✓; endpoints + gating + idempotency (T6) ✓; frontend (T7–T8) ✓; plugin parity (T9) ✓; e2e (T10) ✓; notes/folder tombstone — folder already shipped, single-note (T12) ✓. Spec section "upload on web" is explicitly Phase 3 (out of scope). Spec's separate `attachment_changed` socket → deliberately replaced by `note_changed`+`kind` (documented in re-scope note).
- **Type consistency:** `move_attachment/4` → `{:ok, att} | {:error, :conflict | :not_found}` used identically in controller; `batch_move/4` → `{:ok, %{moved}} | {:error, {:conflict|:not_found, path}}`; hooks post `{paths, target_folder}` matching the controller's `%{"paths" => _, "target_folder" => _}`.
- **Placeholders:** none — every code step shows real code; the two soft spots (frontend hook unit test harness may be absent; `unwrap_tenant` return shape) are flagged inline with concrete fallbacks, not left as TODO.

---

## Follow-ups (filed, not built here)

1. Tombstone pruning / GC (bounded growth: one per move, N+1 per folder rename).
2. Reconcile divergence audit (offline-local-delete detection) → Sync Architecture Overhaul track.
3. Legacy attachment blob re-key backfill (optional; reads already route via `storage_key`).
4. When the plugin adopts the unified `/sync/changes` cursor pull (branches `feat/sync-cursor-pull-b2`), confirm attachment tombstones flow through it too — `list_changes_by_seq` already carries them (no `deleted_at` filter), so expected zero extra work.
