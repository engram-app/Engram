defmodule EngramWeb.FoldersController do
  use EngramWeb, :controller

  alias Engram.Notes

  def index(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, folders} = Notes.list_folders_with_counts(user, vault)
    json(conn, %{folders: Enum.map(folders, fn f -> %{name: f.folder, count: f.count} end)})
  end

  def list(conn, %{"folder" => folder}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, notes} = Notes.list_notes_in_folder(user, vault, folder)

    json(conn, %{
      folder: folder,
      notes: Enum.map(notes, &note_summary/1)
    })
  end

  def list(conn, _params) do
    conn |> put_status(400) |> json(%{error: "folder parameter is required"})
  end

  def rename(conn, %{"old_folder" => old_folder, "new_folder" => new_folder}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, count} = Notes.rename_folder(user, vault, old_folder, new_folder)

    if count == 0 do
      conn |> put_status(404) |> json(%{error: "folder not found"})
    else
      json(conn, %{renamed: true, old_folder: old_folder, new_folder: new_folder, count: count})
    end
  end

  defp note_summary(note) do
    %{
      path: note.path,
      title: note.title,
      folder: note.folder || "",
      tags: note.tags || [],
      version: note.version,
      mtime: note.mtime,
      created_at: note.created_at,
      updated_at: note.updated_at
    }
  end
end
