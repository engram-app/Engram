defmodule EngramWeb.FoldersController do
  use EngramWeb, :controller

  alias Engram.Notes

  def index(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, folders} = Notes.list_folders_with_counts(user, vault)

    # Headless Tree needs stable folder identity (marker id) + parent id to
    # rebuild the hierarchy without string-path prefix matching. Look up the
    # marker id per cleartext path; root ("") and derived (no-marker)
    # folders return id=nil and are skipped as parent candidates.
    markers = Notes.list_folder_markers(user, vault)
    id_by_path = Map.new(markers, fn m -> {m.folder, m.id} end)

    json(conn, %{
      folders:
        Enum.map(folders, fn f ->
          id = Map.get(id_by_path, f.folder)
          parent_id = id_by_path |> Map.get(parent_path(f.folder))

          %{
            id: id,
            name: f.folder,
            count: f.count,
            parent_id: parent_id
          }
        end)
    })
  end

  # nil for top-level ("Projects") and root (""). Joined parent path for
  # nested ("Projects/Engram" -> "Projects").
  defp parent_path(""), do: nil

  defp parent_path(folder) do
    case folder |> String.split("/") |> Enum.drop(-1) do
      [] -> nil
      segments -> Enum.join(segments, "/")
    end
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

  def list_notes(conn, %{"id" => id_str}) do
    with {id, ""} <- Integer.parse(id_str),
         {:ok, notes} <-
           Notes.list_folder_notes_by_id(
             conn.assigns.current_user,
             conn.assigns.current_vault,
             id
           ) do
      json(conn, %{notes: Enum.map(notes, &note_summary/1)})
    else
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
      _ -> conn |> put_status(400) |> json(%{error: "bad_id"})
    end
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
      {:ok, _} ->
        send_resp(conn, 204, "")

      {:error, :no_dek} ->
        send_resp(conn, 204, "")

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: format_error(reason)})
    end
  end

  def rename(conn, %{"old_path" => old_path, "new_path" => new_path}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case Notes.rename_folder(user, vault, old_path, new_path) do
      {:ok, 0} ->
        conn |> put_status(404) |> json(%{error: "folder not found"})

      {:ok, count} ->
        json(conn, %{renamed: true, old_path: old_path, new_path: new_path, count: count})

      {:error, :conflict} ->
        conn |> put_status(409) |> json(%{error: "conflict"})
    end
  end

  # Low-cardinality error formatter for JSON responses; avoids inspect/1 leaking term shape.
  defp format_error(%{__exception__: true} = e), do: Exception.message(e)
  defp format_error(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_error(binary) when is_binary(binary), do: binary
  defp format_error(_), do: "internal_error"

  defp note_summary(note) do
    %{
      id: note.id,
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
