defmodule Engram.Folders do
  @moduledoc """
  Coordinates folder-level operations that span both notes and attachments.

  Folder rename/delete/move must touch the `notes` AND `attachments` tables.
  `Engram.Notes` cannot depend on `Engram.Attachments` (the latter already
  depends on the former), so this module is the single place that fans a folder
  op out to both. Every *content-mutating* folder surface — folder **rename**,
  **batch-delete**, and **batch-move** (REST + MCP) — routes through here so no
  caller can forget the attachment leg.

  The marker-only single DELETE (`DELETE /api/folders/:path`) intentionally does
  NOT route through here: it calls `Notes.delete_folder_marker/3`, which removes
  just the folder marker and deletes no content — the notes AND attachments under
  that path stay live. With nothing deleted, there is nothing to cascade, so a
  coordinator hop would be a no-op.

  Consistency is atomic across BOTH tables: each op wraps the notes leg and the
  attachment leg in a single `Repo.transaction` (the legs' own
  `Repo.with_tenant` transactions nest as savepoints). Any leg error rolls both
  tables back together, so a conflict can never leave notes moved with
  attachments stranded (Bug 3/6).

  Broadcasts are deferred to commit (Fix #1): `atomic/1` brackets the outer
  transaction with `Engram.Sync.Broadcast.deferred/1`, so every per-item
  `note_changed` event the legs emit (routed through `Sync.Broadcast.emit/3`)
  is buffered and flushed ONLY after the outer transaction commits — and
  discarded entirely on rollback. No more phantom delete/upsert events for a
  cascade that a later conflict unwinds.
  """

  alias Engram.Attachments
  alias Engram.Notes
  alias Engram.Repo
  alias Engram.Sync.Broadcast

  @type counts :: %{notes: non_neg_integer(), attachments: non_neg_integer()}

  # Bug 3 / Bug 6 — atomicity across both tables.
  #
  # Each leg (`Notes.*`, `Attachments.*`) runs its own `Repo.with_tenant`
  # transaction internally. We wrap BOTH legs in a single outer
  # `Repo.transaction` so the inner leg transactions nest as savepoints, and on
  # ANY leg error we `Repo.rollback/1`, unwinding BOTH tables together. Without
  # this, a clean notes leg followed by an attachment-leg conflict left notes
  # moved while attachments stayed put (a permanent split / half-delete).
  #
  # The outer transaction deliberately sets NO tenant context — each leg's own
  # `with_tenant` sets and tears down `app.current_tenant` per call. Because the
  # legs run sequentially (not nested under one another), they don't clobber
  # each other's tenant key.
  defp atomic(fun) do
    # Defer cascade broadcasts until AFTER the outer transaction resolves.
    # Each leg's per-item broadcast routes through `Sync.Broadcast.emit/3`,
    # which — because the buffer is active inside `deferred/1` — buffers rather
    # than fires. `deferred/1` then flushes the buffer iff the transaction
    # committed ({:ok, _}) or discards it on rollback ({:error, _}). The buffer
    # brackets the transaction (OUTSIDE the txn) so emits happen INSIDE it via
    # the legs → buffered → flushed post-commit / discarded post-rollback. This
    # closes the phantom-event window where an inner leg's broadcast fired as
    # its savepoint released, before a later attachment conflict rolled the data
    # back, leaving clients with delete/upsert events that never persisted.
    Broadcast.deferred(fn ->
      Repo.transaction(fn ->
        case fun.() do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end

  @spec rename(map(), map(), String.t(), String.t()) :: {:ok, counts()} | {:error, term()}
  def rename(user, vault, old_folder, new_folder) do
    atomic(fn ->
      with {:ok, notes} <- Notes.rename_folder(user, vault, old_folder, new_folder),
           {:ok, atts} <- Attachments.rename_folder(user, vault, old_folder, new_folder) do
        {:ok, %{notes: notes, attachments: atts}}
      end
    end)
  end

  @spec batch_delete(map(), map(), [String.t()]) :: {:ok, counts()} | {:error, term()}
  def batch_delete(_user, _vault, []), do: {:ok, %{notes: 0, attachments: 0}}

  def batch_delete(user, vault, marker_ids) do
    atomic(fn ->
      with {:ok, %{deleted: notes, folders: folders}} <-
             Notes.batch_delete_folders(user, vault, marker_ids),
           {:ok, atts} <- delete_attachments_for(user, vault, folders) do
        {:ok, %{notes: notes, attachments: atts}}
      end
    end)
  end

  @spec batch_move(map(), map(), [String.t()], String.t() | {:path, String.t()}) ::
          {:ok, counts()} | {:error, term()}
  def batch_move(_user, _vault, [], _target), do: {:ok, %{notes: 0, attachments: 0}}

  def batch_move(user, vault, marker_ids, target) do
    atomic(fn ->
      with {:ok, %{moved: notes, pairs: pairs}} <-
             Notes.batch_move_folders(user, vault, marker_ids, target),
           {:ok, atts} <- rename_attachments_for(user, vault, pairs) do
        {:ok, %{notes: notes, attachments: atts}}
      end
    end)
  end

  # Perf (finding #9): scan the vault's attachments ONCE per batch op, then
  # partition the decrypted paths across the N folders — instead of calling
  # `Attachments.delete_folder`/`rename_folder` per folder, each of which ran its
  # own full `list_attachments` scan (O(N × total_attachments) wasted DB work).
  # The pre-filtered paths feed the leaner explicit-list attachment entry points
  # (`batch_delete/3` for delete; `move_folder_pairs/3` for rename) so the whole
  # batch still commits inside the coordinator's `atomic/1` transaction.

  defp delete_attachments_for(_user, _vault, []), do: {:ok, 0}

  defp delete_attachments_for(user, vault, folders) do
    with {:ok, metas} <- Attachments.list_attachments(user, vault) do
      prefixes = Enum.map(folders, &folder_prefix/1)

      paths =
        metas
        |> Enum.map(& &1.path)
        |> Enum.filter(fn path -> Enum.any?(prefixes, &String.starts_with?(path, &1)) end)

      {:ok, %{deleted: n}} = Attachments.batch_delete(user, vault, paths)
      {:ok, n}
    end
  end

  defp rename_attachments_for(_user, _vault, []), do: {:ok, 0}

  defp rename_attachments_for(user, vault, pairs) do
    with {:ok, metas} <- Attachments.list_attachments(user, vault) do
      move_pairs =
        Enum.flat_map(metas, fn %{path: old_path} ->
          case rename_target(old_path, pairs) do
            {:ok, new_path} -> [{old_path, new_path}]
            :no_match -> []
          end
        end)

      Attachments.move_folder_pairs(user, vault, move_pairs)
    end
  end

  defp folder_prefix(folder), do: String.trim_trailing(folder, "/") <> "/"

  # Maps a decrypted attachment path to its new path under whichever {old, new}
  # folder pair owns it (first match wins; folder renames don't overlap). Mirrors
  # `Attachments.rename_folder/4`'s prefix-slice derivation, preserving nesting.
  defp rename_target(path, pairs) do
    Enum.find_value(pairs, :no_match, fn {old, new} ->
      old = String.trim_trailing(old, "/")
      new = String.trim_trailing(new, "/")
      prefix = old <> "/"

      if String.starts_with?(path, prefix) do
        {:ok, new <> String.slice(path, String.length(old)..-1//1)}
      end
    end)
  end
end
