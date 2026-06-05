defmodule EngramWeb.FoldersController do
  use EngramWeb, :controller

  alias Engram.Notes

  def index(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, folders} = Notes.list_folders_with_counts(user, vault)
    json(conn, %{folders: Enum.map(folders, fn f -> %{name: f.folder, count: f.count} end)})
  end

  def explicit(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, names} = Notes.list_explicit_folders(user, vault)
    json(conn, %{folders: Enum.map(names, &%{name: &1})})
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

  def create(conn, %{"folder" => folder}) when is_binary(folder) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case Notes.create_folder_marker(user, vault, folder) do
      {:ok, marker} ->
        conn
        |> put_status(:created)
        |> json(%{folder: %{name: marker.folder, count: 0}})

      {:error, :root_folder_not_marker} ->
        conn
        |> put_status(422)
        |> json(%{error: "folder must not be empty"})

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: format_error(reason)})
    end
  end

  def create(conn, _params) do
    conn |> put_status(422) |> json(%{error: "folder parameter is required"})
  end

  def delete(conn, %{"path" => path_segments}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    folder = Enum.map_join(path_segments, "/", &URI.decode/1)

    # Idempotent: treat :no_dek (user never encrypted anything) as "nothing to delete".
    case Notes.delete_folder_marker(user, vault, folder) do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, :no_dek} -> send_resp(conn, 204, "")
    end
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

  # Low-cardinality error formatter for JSON responses; avoids inspect/1 leaking term shape.
  defp format_error(%{__exception__: true} = e), do: Exception.message(e)
  defp format_error(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_error(binary) when is_binary(binary), do: binary
  defp format_error(_), do: "internal_error"

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
