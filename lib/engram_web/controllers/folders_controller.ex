defmodule EngramWeb.FoldersController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Engram.Notes
  alias EngramWeb.Schemas

  operation(:index,
    operation_id: "folders-index",
    summary: "List folders",
    description:
      "Returns every folder in the current vault with its note count, plus a stable marker id " <>
        "and parent id so clients can rebuild the folder hierarchy. Derived (no-marker) folders " <>
        "and the root return a null id and are not eligible as parents.",
    tags: ["Folders"],
    responses: [ok: {"Folders", "application/json", Schemas.FoldersResponse}]
  )

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

  operation(:explicit,
    operation_id: "folders-explicit",
    summary: "List explicitly-created (empty-capable) folders",
    description:
      "Returns the names of folders that were created explicitly (via a folder marker) and can " <>
        "therefore exist while empty, as opposed to folders merely derived from note paths.",
    tags: ["Folders"],
    responses: [ok: {"Folder names", "application/json", Schemas.FolderNamesResponse}]
  )

  def explicit(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, names} = Notes.list_explicit_folders(user, vault)
    json(conn, %{folders: Enum.map(names, &%{name: &1})})
  end

  operation(:list,
    operation_id: "folders-list",
    summary: "List notes in a folder (metadata only)",
    description:
      "Returns metadata (no content) for the notes in the folder named by the required `folder` " <>
        "query param. Returns 400 when the param is missing.",
    tags: ["Folders"],
    parameters: [folder: [in: :query, type: :string, required: true, description: "Folder path"]],
    responses: [
      ok: {"Folder notes", "application/json", Schemas.FolderListResponse},
      bad_request: {"Missing folder param", "application/json", Schemas.Error}
    ]
  )

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

  operation(:list_notes,
    operation_id: "folders-list-notes",
    summary: "List notes in a folder by id (metadata only)",
    description:
      "Returns metadata (no content) for the notes in the folder identified by its marker UUID. " <>
        "Returns 400 for a malformed UUID and 404 when no such folder exists.",
    tags: ["Folders"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Folder UUID"]],
    responses: [
      ok: {"Folder notes", "application/json", Schemas.FolderNotesResponse},
      bad_request: {"Invalid UUID", "application/json", Schemas.Error},
      not_found: {"No such folder", "application/json", Schemas.Error}
    ]
  )

  def list_notes(conn, %{"id" => id_str}) do
    with {:ok, id} <- Ecto.UUID.cast(id_str),
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

  operation(:create,
    operation_id: "folders-create",
    summary: "Create a folder",
    description:
      "Creates an explicit folder marker so the folder can exist while empty. Returns 201 with " <>
        "the folder (count 0). An empty or root folder path is rejected with 422.",
    tags: ["Folders"],
    request_body:
      {"Folder path", "application/json", Schemas.CreateFolderRequest, required: true},
    responses: [
      created: {"Created", "application/json", Schemas.FolderResponse},
      unprocessable_entity: {"Empty/root folder rejected", "application/json", Schemas.Error}
    ]
  )

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

  operation(:delete,
    operation_id: "folders-delete",
    summary: "Delete a folder by path",
    description:
      "Removes the folder marker for the given path. Idempotent — deleting a non-existent or " <>
        "never-encrypted folder still returns 204.",
    tags: ["Folders"],
    parameters: [path: [in: :path, type: :string, required: true, description: "Folder path"]],
    responses: [no_content: "Deleted (empty body)"]
  )

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

  operation(:rename,
    operation_id: "folders-rename",
    summary: "Rename / move a folder",
    description:
      "Renames or moves a folder from `old_path` to `new_path`, re-homing every note beneath it, " <>
        "and returns the affected note count. Returns 404 when the source folder does not exist and " <>
        "409 when the target path is already occupied.",
    tags: ["Folders"],
    request_body: {"Old + new path", "application/json", Schemas.RenameRequest, required: true},
    responses: [
      ok: {"Renamed", "application/json", Schemas.FolderRenameResponse},
      not_found: {"No such folder", "application/json", Schemas.Error},
      conflict: {"Target exists", "application/json", Schemas.Error}
    ]
  )

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

  operation(:batch_delete,
    operation_id: "folders-batch-delete",
    summary: "Delete folders by id (idempotent)",
    description:
      "Deletes multiple folders by marker id in a single transaction and returns the deleted " <>
        "count. Requires the `X-Idempotency-Key` header — a retry within the TTL replays the cached " <>
        "result. Returns 404/409 (with the offending `item_id`) if any id is missing or conflicts.",
    tags: ["Folders"],
    request_body: {"Folder ids", "application/json", Schemas.BatchIdsRequest, required: true},
    responses: [
      ok: {"Deleted count", "application/json", Schemas.DeletedCount},
      bad_request: {"Invalid ids", "application/json", Schemas.Error},
      not_found: {"Some ids not found", "application/json", Schemas.Error},
      conflict: {"Conflict", "application/json", Schemas.Error}
    ]
  )

  def batch_delete(conn, %{"ids" => ids}) when is_list(ids) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case parse_uuid_list(ids) do
      :error ->
        conn |> put_status(400) |> json(%{error: "invalid_ids"})

      {:ok, ids} ->
        case Notes.batch_delete_folders(user, vault, ids) do
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
    end
  end

  def batch_delete(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: ids"})
  end

  operation(:batch_move,
    operation_id: "folders-batch-move",
    summary: "Move folders under a new parent (idempotent)",
    description:
      "Re-parents multiple folders under `target_parent_id` (or the literal `\"root\"` for top " <>
        "level) in one transaction and returns the moved count. Requires the `X-Idempotency-Key` " <>
        "header. Returns 404 for a missing id and 409 (with `item_id`) on a conflict or a cycle.",
    tags: ["Folders"],
    request_body:
      {"Ids + target parent", "application/json", Schemas.BatchMoveFoldersRequest, required: true},
    responses: [
      ok: {"Moved count", "application/json", Schemas.MovedCount},
      bad_request: {"Invalid input", "application/json", Schemas.Error},
      not_found: {"Some ids not found", "application/json", Schemas.Error},
      conflict: {"Conflict", "application/json", Schemas.Error}
    ]
  )

  def batch_move(conn, %{"ids" => ids, "target_parent_id" => tgt}) when is_list(ids) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, ids} <- parse_uuid_list(ids),
         {:ok, tgt} <- parse_move_target(tgt) do
      case Notes.batch_move_folders(user, vault, ids, tgt) do
        {:ok, %{moved: n}} ->
          body = %{moved: n}
          Engram.Idempotency.remember(conn.assigns.idempotency_key, %{status: 200, body: body})

          broadcast_batch(user, vault, %{
            op: "move",
            ids: ids,
            target_parent_id: tgt
          })

          json(conn, body)

        {:error, {:not_found, id}} ->
          conn |> put_status(404) |> json(%{error: "not_found", item_id: id})

        {:error, {:conflict, id}} ->
          conn |> put_status(409) |> json(%{error: "conflict", item_id: id})

        {:error, {:cycle, id}} ->
          conn |> put_status(409) |> json(%{error: "cycle", item_id: id})

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
    |> json(%{error: "missing required params: ids, target_parent_id"})
  end

  # Low-cardinality error formatter for JSON responses; avoids inspect/1 leaking term shape.
  defp format_error(%{__exception__: true} = e), do: Exception.message(e)
  defp format_error(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_error(binary) when is_binary(binary), do: binary
  defp format_error(_), do: "internal_error"

  defp parse_uuid_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case parse_uuid(item) do
        {:ok, n} -> {:cont, {:ok, [n | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp parse_uuid(s) when is_binary(s), do: Ecto.UUID.cast(s)
  defp parse_uuid(_), do: :error

  # Move target is either a folder-marker UUID or the literal "root" sentinel
  # (top level — no parent marker). "root" must bypass the UUID cast.
  defp parse_move_target("root"), do: {:ok, "root"}
  defp parse_move_target(s) when is_binary(s), do: parse_uuid(s)
  defp parse_move_target(_), do: :error

  defp broadcast_batch(user, vault, payload) do
    EngramWeb.Endpoint.broadcast!(
      "sync:#{user.id}:#{vault.id}",
      "folders.batch",
      payload
    )
  end

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
