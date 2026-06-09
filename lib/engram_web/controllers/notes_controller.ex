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

        {:error, :notes_cap_reached} ->
          # Pricing v2 §G — Free notes_cap (and Starter at higher ceiling)
          # enforced server-side. 402 Payment Required signals plan limit
          # to the client; UX can prompt upgrade.
          conn
          |> put_status(402)
          |> json(%{error: "notes_cap_reached", upgrade_required: true})

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

      {:error, :conflict} ->
        conn |> put_status(409) |> json(%{error: "conflict"})

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

  def show_by_id(conn, %{"id" => id_str}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {id, ""} <- Integer.parse(id_str),
         {:ok, note} <- Notes.get_note_by_id(user, vault, id) do
      json(conn, note_json(note))
    else
      :error -> conn |> put_status(400) |> json(%{error: "invalid id"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
      {_, _rest} -> conn |> put_status(400) |> json(%{error: "invalid id"})
    end
  end

  def delete_by_id(conn, %{"id" => id_str}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {id, ""} <- Integer.parse(id_str),
         :ok <- Notes.delete_note_by_id(user, vault, id) do
      json(conn, %{deleted: true})
    else
      :error -> conn |> put_status(400) |> json(%{error: "invalid id"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
      {_, _rest} -> conn |> put_status(400) |> json(%{error: "invalid id"})
    end
  end

  def changes(conn, %{"since" => since_str}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case DateTime.from_iso8601(since_str) do
      {:ok, since, _} ->
        {:ok, changes} = Notes.list_changes(user, vault, since)

        json(conn, %{
          changes: Enum.map(changes, &change_json/1),
          server_time: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "invalid since timestamp"})
    end
  end

  def changes(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: since"})
  end

  # ---------------------------------------------------------------------------
  # Batch ops
  # ---------------------------------------------------------------------------
  #
  # Idempotency: the X-Idempotency-Key header is required (enforced by
  # EngramWeb.Plugs.IdempotencyKey before this action runs). On success we
  # cache the (status, body) tuple so a retry within the TTL replays the
  # exact response without re-executing the transaction. The plug short-
  # circuits replays before they reach us.
  #
  # Note: PubSub broadcast still lives in the action (post-commit). If the
  # commit succeeds but the broadcast crashes, the cache is already set, so
  # a retry returns the cached 200 but does NOT re-broadcast. Tracked as a
  # follow-up (after-commit hook).

  def batch_delete(conn, %{"ids" => ids}) when is_list(ids) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, ids} <- parse_int_list(ids) do
      case Notes.batch_delete_notes(user, vault, ids) do
        {:ok, %{deleted: n}} ->
          body = %{deleted: n}
          Engram.Idempotency.remember(conn.assigns.idempotency_key, %{status: 200, body: body})
          broadcast_batch(user, vault, %{op: "delete", ids: ids})
          json(conn, body)

        {:error, {:not_found, id}} ->
          conn |> put_status(404) |> json(%{error: "not_found", item_id: id})

        {:error, {:conflict, id}} ->
          conn |> put_status(409) |> json(%{error: "conflict", item_id: id})

        {:error, _reason} ->
          conn |> put_status(500) |> json(%{error: "internal"})
      end
    else
      :error -> conn |> put_status(400) |> json(%{error: "invalid_ids"})
    end
  end

  def batch_delete(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: ids"})
  end

  def batch_move(conn, %{"ids" => ids, "target_folder_id" => tgt}) when is_list(ids) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, ids} <- parse_int_list(ids),
         {:ok, tgt} <- parse_int(tgt) do
      case Notes.batch_move_notes(user, vault, ids, tgt) do
        {:ok, %{moved: n}} ->
          body = %{moved: n}
          Engram.Idempotency.remember(conn.assigns.idempotency_key, %{status: 200, body: body})

          broadcast_batch(user, vault, %{
            op: "move",
            ids: ids,
            target_folder_id: tgt
          })

          json(conn, body)

        {:error, {:not_found, id}} ->
          conn |> put_status(404) |> json(%{error: "not_found", item_id: id})

        {:error, {:conflict, id}} ->
          conn |> put_status(409) |> json(%{error: "conflict", item_id: id})

        {:error, _reason} ->
          conn |> put_status(500) |> json(%{error: "internal"})
      end
    else
      :error -> conn |> put_status(400) |> json(%{error: "invalid_ids"})
    end
  end

  def batch_move(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing required params: ids, target_folder_id"})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp note_json(note) do
    %{
      id: note.id,
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
      id: change.id,
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

  defp parse_int_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case parse_int(item) do
        {:ok, n} -> {:cont, {:ok, [n | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp parse_int(n) when is_integer(n), do: {:ok, n}

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_int(_), do: :error

  defp broadcast_batch(user, vault, payload) do
    EngramWeb.Endpoint.broadcast!(
      "sync:#{user.id}:#{vault.id}",
      "notes.batch",
      payload
    )
  end
end
