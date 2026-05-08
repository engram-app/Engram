defmodule EngramWeb.NotesController do
  use EngramWeb, :controller

  alias Engram.Notes

  @max_note_bytes 10 * 1024 * 1024

  def upsert(conn, params) do
    content = params["content"] || params[:content] || ""

    if byte_size(content) > @max_note_bytes do
      conn |> put_status(413) |> json(%{error: "note exceeds maximum size of 10MB"})
    else
      user = conn.assigns.current_user
      vault = conn.assigns.current_vault

      case Notes.upsert_note(user, vault, params) do
        {:ok, note} ->
          json(conn, %{note: note_json(note)})

        {:error, :version_conflict, server_note} ->
          conn
          |> put_status(409)
          |> json(%{conflict: true, server_note: note_json(server_note)})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(422)
          |> json(%{errors: format_errors(changeset)})

        {:error, reason} ->
          require Logger

          # T3.0.1 follow-up — log a low-cardinality label, not the raw
          # struct. The catch-all branch can be reached with %Ecto.Changeset{},
          # %Postgrex.Error{}, plain atoms, or future variants. Any of those
          # could carry virtual decrypted note fields if a future regression
          # surfaces a %Note{} inside a reason tuple. Label keeps the metric
          # signal without the leak surface.
          Logger.error("upsert_note returned unexpected error",
            reason_label: classify_reason(reason),
            user_id: user.id,
            vault_id: vault.id
          )

          conn |> put_status(500) |> json(%{error: "internal"})
      end
    end
  end

  def append(conn, %{"path" => path, "text" => text}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case Notes.get_note(user, vault, path) do
      {:ok, note} ->
        content = String.trim_trailing(note.content, "\n") <> "\n" <> text

        case Notes.upsert_note(user, vault, %{
               "path" => path,
               "content" => content,
               "mtime" => note.mtime
             }) do
          {:ok, updated} ->
            json(conn, %{created: false, path: path, note: note_json(updated)})

          {:error, changeset} ->
            conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
        end

      {:error, :not_found} ->
        # Create new note with heading from filename + appended text
        filename = path |> Path.basename(".md")
        content = "# #{filename}\n\n#{text}"
        mtime = System.os_time(:second) * 1.0

        case Notes.upsert_note(user, vault, %{
               "path" => path,
               "content" => content,
               "mtime" => mtime
             }) do
          {:ok, note} ->
            json(conn, %{created: true, path: path, note: note_json(note)})

          {:error, changeset} ->
            conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
        end
    end
  end

  def show(conn, %{"path" => path_parts}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    path = Enum.join(List.wrap(path_parts), "/")

    case Notes.get_note(user, vault, path) do
      {:ok, note} -> json(conn, note_json(note))
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def rename(conn, %{"old_path" => old_path, "new_path" => new_path}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case Notes.rename_note(user, vault, old_path, new_path) do
      {:ok, note} ->
        json(conn, %{renamed: true, old_path: old_path, new_path: new_path, note: note_json(note)})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def delete(conn, %{"path" => path_parts}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    path = Enum.join(List.wrap(path_parts), "/")
    Notes.delete_note(user, vault, path)
    json(conn, %{deleted: true})
  end

  def changes(conn, %{"since" => since_str}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case DateTime.from_iso8601(since_str) do
      {:ok, since, _} ->
        {:ok, changes} = Notes.list_changes(user, vault, since)

        json(conn, %{
          changes: Enum.map(changes, &change_json/1),
          server_time: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "invalid since timestamp"})
    end
  end

  def changes(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: since"})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp note_json(note) do
    %{
      path: note.path,
      title: note.title,
      folder: note.folder || "",
      tags: note.tags || [],
      version: note.version,
      content: note.content || "",
      mtime: note.mtime,
      updated_at: note.updated_at
    }
  end

  defp change_json(change) do
    %{
      path: change.path,
      title: change.title,
      folder: change.folder || "",
      tags: change.tags || [],
      version: change.version,
      mtime: change.mtime,
      content: change.content || "",
      deleted: change.deleted,
      updated_at: change.updated_at
    }
  end

  defp format_errors(changeset), do: EngramWeb.format_errors(changeset)

  defp classify_reason(reason) when is_atom(reason), do: reason
  defp classify_reason(%Ecto.Changeset{}), do: :changeset
  defp classify_reason(%{__exception__: true} = e), do: e.__struct__
  defp classify_reason(_), do: :unknown
end
