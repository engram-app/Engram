defmodule EngramWeb.NotesController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Crypto
  alias Engram.Links
  alias Engram.Logger.Metadata
  alias Engram.Notes
  alias Engram.Repo
  alias EngramWeb.BatchOps

  action_fallback EngramWeb.FallbackController

  require Logger

  operation(:upsert,
    operation_id: "notes-upsert",
    summary: "Create or update a note",
    description:
      "Creates a note or updates the existing one at the same path. Updates are merged " <>
        "convergently (CRDT) with the stored content. Optionally pass `base_hash` — the " <>
        "`content_hash` you last read — for compare-and-swap semantics: if the note changed " <>
        "since that read, the write returns 409 with the current server note instead of " <>
        "merging. Notes over 10MB are rejected with 413, and exceeding the plan's note cap " <>
        "returns 402.",
    tags: ["Notes"],
    request_body:
      {"Note to upsert", "application/json", Schemas.UpsertNoteRequest, required: true},
    responses: [
      created: {"Created/updated", "application/json", Schemas.NoteResponse},
      conflict: {"Version conflict", "application/json", Schemas.Conflict},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error},
      request_entity_too_large: {"Note exceeds 10MB", "application/json", Schemas.Error}
    ]
  )

  def upsert(conn, params) do
    content = params["content"] || params[:content] || ""

    if byte_size(content) > Notes.max_note_bytes() do
      too_large(conn)
    else
      user = conn.assigns.current_user
      vault = conn.assigns.current_vault
      actor = EngramWeb.WriteActor.for_conn(conn)

      # One transaction: the write, its job inserts and the response's links
      # read. Rendered inside it, sent after it commits.
      result =
        in_write_txn(user, fn user ->
          case Notes.upsert_note(user, vault, params, actor: actor) do
            {:ok, note} -> {:ok, note_json(note, user)}
            {:error, :version_conflict, server} -> {:conflict, note_json(server, user)}
            other -> other
          end
        end)

      case result do
        {:ok, body} ->
          json(conn, %{note: body})

        {:conflict, server_note} ->
          conn
          |> put_status(409)
          |> json(%{conflict: true, server_note: server_note})

        {:error, %Ecto.Changeset{}} = error ->
          error

        {:error, {:notes_cap_reached, limit, current}} ->
          # Pricing v2 §G — Free notes_cap (and Starter at higher ceiling)
          # enforced server-side. 402 Payment Required signals plan limit
          # via the standardized LimitResponse shape (see Free-tier launch §4.5).
          EngramWeb.LimitResponse.halt(
            conn,
            "notes_cap_exceeded",
            :notes_cap,
            limit,
            current
          )

        {:error, :recently_deleted} ->
          # Delete-wins: a create at a path deleted seconds ago, identical
          # content — a stale re-push racing an explicit delete. Refuse so the
          # delete stands; the client converges by dropping its local copy.
          conn |> put_status(409) |> json(%{conflict: true, reason: "recently_deleted"})

        # The note was deleted while this write was losing its snapshot fence
        # (#1335). Without this clause it falls to the catch-all and answers 500
        # `internal`, which the plugin treats as transient and re-queues forever
        # instead of dropping a note that is genuinely gone.
        {:error, :note_deleted} ->
          conn |> put_status(404) |> json(%{error: "not_found"})

        # Under the byte check above, but invalid UTF-8 scrubbed to U+FFFD
        # (3 bytes each) can grow past the cap inside upsert_note.
        {:error, :too_large} ->
          too_large(conn)

        {:error, reason} ->
          require Logger

          # T3.0.1 follow-up — log a low-cardinality label, not the raw
          # struct. The catch-all branch can be reached with %Ecto.Changeset{},
          # %Postgrex.Error{}, plain atoms, or future variants. Any of those
          # could carry virtual decrypted note fields if a future regression
          # surfaces a %Note{} inside a reason tuple. Label keeps the metric
          # signal without the leak surface.
          Logger.error(
            "upsert_note returned unexpected error",
            Metadata.with_category(:error, :sync,
              reason_label: classify_reason(reason),
              user_id: user.id,
              vault_id: vault.id
            )
          )

          conn |> put_status(500) |> json(%{error: "internal"})
      end
    end
  end

  operation(:append,
    operation_id: "notes-append",
    summary: "Append text to a note (creating it if absent)",
    description:
      "Appends `text` to the note at `path`, returning `created: false`. If the note does not " <>
        "exist it is created with a heading derived from the filename plus the text, returning " <>
        "`created: true`.",
    tags: ["Notes"],
    request_body: {"Path + text", "application/json", Schemas.AppendRequest, required: true},
    responses: [
      ok: {"Appended", "application/json", Schemas.AppendResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def append(conn, %{"path" => path, "text" => text}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    actor = EngramWeb.WriteActor.for_conn(conn)

    # Append is a read-modify-write, so it reads the AUTHORITY, not the
    # `notes.content` facade, UNCONDITIONALLY. Do not "optimise" this with the
    # feed's tail-presence check (#1339): deriving the new body from a facade
    # that is stale for any reason the tail does not witness truncates the note
    # (#1159, seen in prod CI as a note arriving on the other device as just the
    # appended fragment). `Notes.rmw_note/5` also serializes concurrent appends
    # (a second append used to erase the first) and merges into the exact doc
    # the new body was derived from (it used to duplicate un-checkpointed edits).
    #
    # One transaction: a miss comes back holding the vault lock, so the create
    # below cannot race another append's create. The response is rendered after
    # it commits.
    rebuild = fn base -> String.trim_trailing(base, "\n") <> "\n" <> text end

    result =
      in_write_txn(user, fn user ->
        case Notes.rmw_note(user, vault, path, rebuild, actor: actor) do
          {{:error, :not_found}, _} ->
            # Create new note with heading from filename + appended text
            filename = path |> Path.basename(".md")

            {:created,
             Notes.upsert_note(
               user,
               vault,
               %{
                 "path" => path,
                 "content" => "# #{filename}\n\n#{text}",
                 "mtime" => System.os_time(:second) * 1.0
               },
               actor: actor
             )
             |> render_in_txn(user)}

          {upserted, _} ->
            {:appended, render_in_txn(upserted, user)}
        end
      end)

    append_response(conn, user, path, result)
  end

  # note_json's links read joins the request transaction.
  defp render_in_txn({:ok, note}, user), do: {:ok, {:rendered, note_json(note, user)}}

  defp render_in_txn({:error, :version_conflict, server}, user),
    do: {:error, :version_conflict, {:rendered, note_json(server, user)}}

  defp render_in_txn(other, _user), do: other

  # The DEK could not be provisioned (in_write_txn/2): nothing was read or
  # written. Same retryable refusal as an unreadable authority.
  defp append_response(conn, user, path, {:error, reason}),
    do: append_response(conn, user, path, {:appended, {:error, {:authority, reason}}})

  defp append_response(conn, _user, path, {kind, {:ok, {:rendered, body}}}),
    do: json(conn, %{created: kind == :created, path: path, note: body})

  # Refuse rather than fall back to the facade. Falling back is exactly the bug:
  # it is the path that silently truncates the note. A failed append is
  # recoverable; a destroyed note is not.
  defp append_response(conn, user, _path, {:appended, {:error, {:authority, reason}}}) do
    Logger.error(
      "note_append_authority_unavailable",
      # classify_reason/1, not inspect/1: the reason can carry a %Note{} with
      # decrypted virtual fields, and this file's own T3.0.6 guard
      # (no_inspect_in_json_response_test) exists to stop that leaking into
      # logs. The label keeps the signal.
      Metadata.with_category(:error, :sync,
        user_id: user.id,
        reason_label: classify_reason(reason)
      )
    )

    conn
    |> put_status(503)
    |> json(%{error: "append_unavailable", reason: "could not read current note content"})
  end

  # Delete-wins: append-as-create races an explicit delete of the same path.
  # Refuse cleanly (409); format_errors/1 expects a changeset.
  defp append_response(conn, _user, _path, {_, {:error, :recently_deleted}}),
    do: conn |> put_status(409) |> json(%{conflict: true, reason: "recently_deleted"})

  # The 3-tuple: `{:error, changeset}` does not match it. Same body shape
  # upsert/2 returns, so the client has one conflict contract.
  defp append_response(conn, _user, _path, {_, {:error, :version_conflict, {:rendered, body}}}) do
    conn
    |> put_status(409)
    |> json(%{conflict: true, server_note: body})
  end

  defp append_response(conn, _user, _path, {_, {:error, :note_deleted}}),
    do: conn |> put_status(404) |> json(%{error: "not_found"})

  defp append_response(conn, _user, _path, {_, {:error, :too_large}}), do: too_large(conn)

  # A legacy row's tail kept appearing under the lock: nothing was written and
  # a retry reads it. Same retryable 409 shape as recently_deleted.
  defp append_response(conn, _user, _path, {_, {:error, :stale_tail}}),
    do: conn |> put_status(409) |> json(%{conflict: true, reason: "concurrent_edit"})

  # Append-as-create past the plan's notes cap: upsert/2's 402.
  defp append_response(conn, _user, _path, {_, {:error, {:notes_cap_reached, limit, current}}}),
    do: EngramWeb.LimitResponse.halt(conn, "notes_cap_exceeded", :notes_cap, limit, current)

  defp append_response(conn, _user, _path, {_, {:error, %Ecto.Changeset{} = changeset}}),
    do: conn |> put_status(422) |> json(%{errors: format_errors(changeset)})

  # format_errors/1 raises on anything but a changeset; upsert/2's catch-all.
  defp append_response(conn, user, _path, {_, {:error, reason}}) do
    Logger.error(
      "note_append returned unexpected error",
      Metadata.with_category(:error, :sync,
        reason_label: classify_reason(reason),
        user_id: user.id
      )
    )

    conn |> put_status(500) |> json(%{error: "internal"})
  end

  operation(:show,
    operation_id: "notes-show",
    summary: "Get a note by path",
    description:
      "Returns the full note (including content) at the given slash-separated path, or 404 if " <>
        "no note exists there.",
    tags: ["Notes"],
    parameters: [
      path: [in: :path, type: :string, required: true, description: "Note path (slash-separated)"]
    ],
    responses: [
      ok: {"Note", "application/json", Schemas.Note},
      not_found: {"No such note", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"path" => path_parts}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    path = Enum.join(List.wrap(path_parts), "/")

    # One transaction for the note and its links. The DEK is warmed first: a
    # DekCache miss unwraps through KMS, which must not run inside it.
    _ = Crypto.get_dek(user)

    result =
      Repo.with_tenant!(user.id, fn ->
        with {:ok, note} <- Notes.get_note(user, vault, path), do: {:ok, note_json(note, user)}
      end)

    case result do
      {:ok, body} -> json(conn, body)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  operation(:rename,
    operation_id: "notes-rename",
    summary: "Rename / move a note",
    description:
      "Moves the note from `old_path` to `new_path` and returns the updated note. Returns 404 " <>
        "when the source note is missing and 409 when the target path already exists or the note " <>
        "version conflicts.",
    tags: ["Notes"],
    request_body: {"Old + new path", "application/json", Schemas.RenameRequest, required: true},
    responses: [
      ok: {"Renamed", "application/json", Schemas.RenameNoteResponse},
      not_found: {"No such note", "application/json", Schemas.Error},
      conflict: {"Target exists / version conflict", "application/json", Schemas.Error}
    ]
  )

  def rename(conn, %{"old_path" => old_path, "new_path" => new_path}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case Notes.rename_note(user, vault, old_path, new_path) do
      {:ok, note} ->
        json(conn, %{
          renamed: true,
          old_path: old_path,
          new_path: new_path,
          note: note_json(note, user)
        })

      {:error, :conflict} = error ->
        error

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not found"})

      # rename_note/5 claims the path in the CRDT authority before moving the
      # row, which widened this function's error space from 3 shapes to 12.
      # Everything below was previously a CaseClauseError — and note that
      # `action_fallback` does NOT catch those: it only intercepts a returned
      # non-conn value, so an unmatched clause raised, bypassed the fallback,
      # and produced a 500 plus a Sentry event per request.
      #
      # TRANSIENT — the operation is fine, the authority is momentarily
      # unreachable. These deserve the same "come back" answer as a rotation,
      # not a permanent-looking 500.
      {:error, reason} when reason in [:rotation_in_progress, :mailbox_empty] ->
        retry_later(conn, reason)

      {:error, {:room_exit, _reason}} ->
        retry_later(conn, :room_exit)

      # INTERNAL — a snapshot that will not decrypt, will not encode, or will
      # not persist. Genuinely our problem, and not fixed by retrying.
      {:error, _reason} ->
        conn |> put_status(500) |> json(%{error: "internal"})
    end
  end

  defp retry_later(conn, reason) do
    conn
    |> put_resp_header("retry-after", "30")
    |> put_status(503)
    |> json(%{error: "temporarily unavailable", reason: reason})
  end

  operation(:delete,
    operation_id: "notes-delete",
    summary: "Delete a note by path",
    description:
      "Deletes the note at the given path. Idempotent — deleting a non-existent note still " <>
        "returns `deleted: true`.",
    tags: ["Notes"],
    parameters: [path: [in: :path, type: :string, required: true, description: "Note path"]],
    responses: [ok: {"Deleted", "application/json", Schemas.DeletedFlag}]
  )

  def delete(conn, %{"path" => path_parts}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    path = Enum.join(List.wrap(path_parts), "/")

    Notes.delete_note(user, vault, path, origin_device_id: EngramWeb.OriginDevice.from_conn(conn))

    json(conn, %{deleted: true})
  end

  operation(:show_by_id,
    operation_id: "notes-show-by-id",
    summary: "Get a note by id",
    description:
      "Returns the full note (including content) for the given note UUID. Returns 400 for a " <>
        "malformed UUID and 404 when no such note exists in the vault.",
    tags: ["Notes"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Note UUID"]],
    responses: [
      ok: {"Note", "application/json", Schemas.Note},
      bad_request: {"Invalid UUID", "application/json", Schemas.Error},
      not_found: {"No such note", "application/json", Schemas.Error}
    ]
  )

  def show_by_id(conn, %{"id" => id_str}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, id} <- Ecto.UUID.cast(id_str),
         {:ok, note} <- Notes.get_note_by_id(user, vault, id) do
      json(conn, note_json(note, user))
    else
      :error -> conn |> put_status(400) |> json(%{error: "invalid id"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  operation(:backlinks,
    operation_id: "notes-backlinks",
    summary: "Get backlinks for a note",
    description:
      "Returns every note that links to the given note UUID (the inverse of a note's own " <>
        "`links`). Returns 400 for a malformed UUID and 404 when no such note exists in the vault.",
    tags: ["Notes"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Note UUID"]],
    responses: [
      ok: {"Backlinks", "application/json", Schemas.Backlinks},
      bad_request: {"Invalid UUID", "application/json", Schemas.Error},
      not_found: {"No such note", "application/json", Schemas.Error}
    ]
  )

  def backlinks(conn, %{"id" => id_str}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, id} <- Ecto.UUID.cast(id_str),
         {:ok, _note} <- Notes.get_note_by_id(user, vault, id) do
      json(conn, %{backlinks: Links.backlinks_for_note(user, id)})
    else
      :error -> conn |> put_status(400) |> json(%{error: "invalid id"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  operation(:delete_by_id,
    operation_id: "notes-delete-by-id",
    summary: "Delete a note by id",
    description:
      "Deletes the note with the given UUID. Returns 400 for a malformed UUID and 404 when no " <>
        "such note exists.",
    tags: ["Notes"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Note UUID"]],
    responses: [
      ok: {"Deleted", "application/json", Schemas.DeletedFlag},
      bad_request: {"Invalid UUID", "application/json", Schemas.Error},
      not_found: {"No such note", "application/json", Schemas.Error}
    ]
  )

  def delete_by_id(conn, %{"id" => id_str}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, id} <- Ecto.UUID.cast(id_str),
         :ok <-
           Notes.delete_note_by_id(user, vault, id,
             origin_device_id: EngramWeb.OriginDevice.from_conn(conn)
           ) do
      json(conn, %{deleted: true})
    else
      :error -> conn |> put_status(400) |> json(%{error: "invalid id"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  operation(:changes,
    operation_id: "notes-changes",
    summary: "Retired timestamp change feed",
    deprecated: true,
    description:
      "Retired. The timestamp-based change feed has been removed; this endpoint always " <>
        "returns 410 Gone. Clients sync via the CRDT sync socket and `GET /sync/manifest` " <>
        "(current plugin versions already do).",
    tags: ["Notes"],
    responses: [
      gone: {"Feed retired", "application/json", Schemas.Error}
    ]
  )

  # Retired timestamp feed (zero authenticated prod traffic). The route stays
  # so old clients get an explicit 410 instead of a generic 404.
  def changes(conn, _params) do
    conn
    |> put_status(410)
    |> json(%{
      error: "gone",
      message:
        "The timestamp change feed was removed. Sync via the CRDT sync socket and " <>
          "/sync/manifest (current plugin versions already do)."
    })
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
    operation_id: "notes-batch-delete",
    summary: "Delete notes by id (idempotent)",
    description:
      "Deletes multiple notes by id in a single transaction and returns the deleted count. " <>
        "Requires the `X-Idempotency-Key` header for safe retries. Returns 404/409 (with the " <>
        "offending `item_id`) if any id is missing or conflicts.",
    tags: ["Notes"],
    request_body: {"Note ids", "application/json", Schemas.BatchIdsRequest, required: true},
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

    case BatchOps.parse_uuid_list(ids) do
      :error ->
        conn |> put_status(400) |> json(%{error: "invalid_ids"})

      {:ok, ids} ->
        # Error tuples ({:not_found, id}/{:conflict, id}/internal) fall
        # through to the action_fallback.
        with {:ok, %{deleted: n}} <- Notes.batch_delete_notes(user, vault, ids) do
          body = %{deleted: n}

          EngramWeb.Plugs.IdempotencyKey.remember(conn, %{status: 200, body: body})

          BatchOps.broadcast_batch(user, vault, "notes.batch", %{op: "delete", ids: ids})
          json(conn, body)
        end
    end
  end

  def batch_delete(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: ids"})
  end

  operation(:batch_move,
    operation_id: "notes-batch-move",
    summary: "Move notes to a folder (idempotent)",
    description:
      "Moves multiple notes into the folder identified by `target_folder_id` (or the literal " <>
        "`\"root\"` for the vault root) in one transaction and returns the moved count. Requires the " <>
        "`X-Idempotency-Key` header. Returns 404/409 (with `item_id`) if any id is missing or conflicts.",
    tags: ["Notes"],
    request_body:
      {"Ids + target folder", "application/json", Schemas.BatchMoveNotesRequest, required: true},
    responses: [
      ok: {"Moved count", "application/json", Schemas.MovedCount},
      bad_request: {"Invalid input", "application/json", Schemas.Error},
      not_found: {"Some ids not found", "application/json", Schemas.Error},
      conflict: {"Conflict", "application/json", Schemas.Error}
    ]
  )

  # Move by folder PATH — works for derived folders (no marker). The target
  # path is sanitized downstream by rename_note, so traversal is not a concern.
  def batch_move(conn, %{"ids" => ids, "target_folder" => folder})
      when is_list(ids) and is_binary(folder) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case BatchOps.parse_uuid_list(ids) do
      {:ok, ids} ->
        result = Notes.batch_move_notes(user, vault, ids, {:path, folder})
        send_move_result(conn, user, vault, ids, result, %{target_folder: folder})

      :error ->
        conn |> put_status(400) |> json(%{error: "invalid_ids"})
    end
  end

  def batch_move(conn, %{"ids" => ids, "target_folder_id" => tgt}) when is_list(ids) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, ids} <- BatchOps.parse_uuid_list(ids),
         {:ok, tgt} <- BatchOps.parse_move_target(tgt) do
      result = Notes.batch_move_notes(user, vault, ids, tgt)
      send_move_result(conn, user, vault, ids, result, %{target_folder_id: tgt})
    else
      :error -> conn |> put_status(400) |> json(%{error: "invalid_ids"})
    end
  end

  def batch_move(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing required params: ids, and target_folder or target_folder_id"})
  end

  # Shared response for both move variants. `broadcast_extra` carries the
  # destination (target_folder path or target_folder_id) to peer sessions.
  # Error tuples ({:not_found, id}/{:conflict, id}/internal) fall through to
  # the action_fallback.
  defp send_move_result(conn, user, vault, ids, result, broadcast_extra) do
    # Batch moves claim in the CRDT authority before moving rows, so they carry
    # the same widened error space `rename/2` handles. Without this the SAME
    # user, mid-rotation, got 503 "try again" from a single rename and 500
    # "internal" from a batch move of the same notes — because FallbackController
    # collapses any unrecognised {:error, _} to 500.
    case result do
      {:error, reason} when reason in [:rotation_in_progress, :mailbox_empty] ->
        retry_later(conn, reason)

      {:error, {:room_exit, _}} ->
        retry_later(conn, :room_exit)

      _ ->
        do_send_move_result(conn, user, vault, ids, result, broadcast_extra)
    end
  end

  defp do_send_move_result(conn, user, vault, ids, result, broadcast_extra) do
    with {:ok, %{moved: n}} <- result do
      body = %{moved: n}

      EngramWeb.Plugs.IdempotencyKey.remember(conn, %{
        status: 200,
        body: body
      })

      BatchOps.broadcast_batch(
        user,
        vault,
        "notes.batch",
        Map.merge(%{op: "move", ids: ids}, broadcast_extra)
      )

      json(conn, body)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # A REST write's one tenant transaction, as the MCP controller runs a tool:
  # the DEK is provisioned and warmed BEFORE it (both can call KMS, which must
  # not run while the transaction holds a connection). A provisioning failure
  # is returned as is; the write's own error handling reports it.
  defp in_write_txn(user, fun) do
    case Crypto.ensure_user_dek(user) do
      {:ok, user} ->
        _ = Crypto.get_dek(user)
        Repo.with_tenant!(user.id, fn -> fun.(user) end)

      {:error, _} = error ->
        error
    end
  end

  defp note_json(note, user) do
    %{
      id: note.id,
      path: note.path,
      title: note.title,
      folder: note.folder || "",
      tags: note.tags || [],
      version: note.version,
      # Protocol rev — clients store the server hash per path so hash-only
      # broadcasts / fields=meta pages can be compared without refetching.
      # The hash is keyed server-side (HMAC); clients treat it as opaque.
      content_hash: note.content_hash,
      mtime: note.mtime,
      updated_at: note.updated_at,
      type: note.type,
      description: note.description,
      resource: note.resource,
      fm_timestamp: note.fm_timestamp,
      fm_created: note.fm_created,
      parse_status: note.parse_status,
      parse_reason: note.parse_reason,
      # Task 9 — outgoing wikilink/embed edges, resolved. Frontend keys its
      # resolution map off `target_text`.
      links: Links.links_for_note(user, note.id)
    }
    |> put_content(note.content)
  end

  # Boundary guard, same rule as Notes.broadcast_change (e2e test_34 class):
  # nil content means a meta-projected struct leaked here (body exists, never
  # loaded) — omit the key so clients fall back to fetching the body, instead
  # of fabricating "" beside the REAL content_hash and seeding 0-byte files
  # as converged forever. Genuinely empty notes are "" (is_binary) and keep
  # serializing as "". nil is unreachable through today's callers (all
  # full-load + decrypt); this pins the boundary for future projections.
  # Public for the regression test only.
  @doc false
  def put_content(map, content) when is_binary(content), do: Map.put(map, :content, content)
  def put_content(map, nil), do: map

  defp format_errors(changeset), do: EngramWeb.format_errors(changeset)

  defp too_large(conn),
    do: conn |> put_status(413) |> json(%{error: "note exceeds maximum size of 10MB"})

  # Delegate to the bounded, total error classifier. The single is_atom clause
  # this replaced raised FunctionClauseError on the very %Ecto.Changeset{} /
  # %Postgrex.Error{} reasons the branch above documents it can receive — the
  # error logger crashing itself. error_kind/1 is total and leak-safe (only a
  # bounded atom escapes; a %Note{} buried in a reason tuple never does).
  defp classify_reason(reason), do: Engram.Telemetry.error_kind(reason)
end
