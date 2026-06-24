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

  Residual: per-item broadcasts inside the attachment leg fire as their inner
  transactions commit, BEFORE the outer rollback can fire — a later failure
  can't retract earlier items' socket events. Clients self-heal on the next
  pull (same trade-off as `Attachments.batch_move/4`).
  """

  alias Engram.Attachments
  alias Engram.Notes
  alias Engram.Repo

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
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
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

  defp delete_attachments_for(user, vault, folders) do
    Enum.reduce_while(folders, {:ok, 0}, fn folder, {:ok, total} ->
      case Attachments.delete_folder(user, vault, folder) do
        {:ok, n} -> {:cont, {:ok, total + n}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp rename_attachments_for(user, vault, pairs) do
    Enum.reduce_while(pairs, {:ok, 0}, fn {old, new}, {:ok, total} ->
      case Attachments.rename_folder(user, vault, old, new) do
        {:ok, n} -> {:cont, {:ok, total + n}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
