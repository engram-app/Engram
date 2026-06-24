defmodule Engram.Folders do
  @moduledoc """
  Coordinates folder-level operations that span both notes and attachments.

  Folder rename/delete/move must touch the `notes` AND `attachments` tables.
  `Engram.Notes` cannot depend on `Engram.Attachments` (the latter already
  depends on the former), so this module is the single place that fans a folder
  op out to both. Every folder-mutating surface (REST + MCP) routes through here
  so no caller can forget the attachment leg.

  Consistency is per-table (not one unified transaction): the note leg commits
  atomically, then the attachment leg cascades. A client may briefly observe the
  note move ahead of the attachment move; sync converges on the next pull.
  """

  alias Engram.Attachments
  alias Engram.Notes

  @type counts :: %{notes: non_neg_integer(), attachments: non_neg_integer()}

  @spec rename(map(), map(), String.t(), String.t()) :: {:ok, counts()} | {:error, term()}
  def rename(user, vault, old_folder, new_folder) do
    with {:ok, notes} <- Notes.rename_folder(user, vault, old_folder, new_folder),
         {:ok, atts} <- Attachments.rename_folder(user, vault, old_folder, new_folder) do
      {:ok, %{notes: notes, attachments: atts}}
    end
  end

  @spec batch_delete(map(), map(), [String.t()]) :: {:ok, counts()} | {:error, term()}
  def batch_delete(_user, _vault, []), do: {:ok, %{notes: 0, attachments: 0}}

  def batch_delete(user, vault, marker_ids) do
    with {:ok, %{deleted: notes, folders: folders}} <-
           Notes.batch_delete_folders(user, vault, marker_ids),
         {:ok, atts} <- delete_attachments_for(user, vault, folders) do
      {:ok, %{notes: notes, attachments: atts}}
    end
  end

  @spec batch_move(map(), map(), [String.t()], String.t() | {:path, String.t()}) ::
          {:ok, counts()} | {:error, term()}
  def batch_move(_user, _vault, [], _target), do: {:ok, %{notes: 0, attachments: 0}}

  def batch_move(user, vault, marker_ids, target) do
    with {:ok, %{moved: notes, pairs: pairs}} <-
           Notes.batch_move_folders(user, vault, marker_ids, target),
         {:ok, atts} <- rename_attachments_for(user, vault, pairs) do
      {:ok, %{notes: notes, attachments: atts}}
    end
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
