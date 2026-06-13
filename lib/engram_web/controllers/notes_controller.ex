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

    with {:ok, id} <- Ecto.UUID.cast(id_str),
         {:ok, note} <- Notes.get_note_by_id(user, vault, id) do
      json(conn, note_json(note))
    else
      :error -> conn |> put_status(400) |> json(%{error: "invalid id"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def delete_by_id(conn, %{"id" => id_str}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, id} <- Ecto.UUID.cast(id_str),
         :ok <- Notes.delete_note_by_id(user, vault, id) do
      json(conn, %{deleted: true})
    else
      :error -> conn |> put_status(400) |> json(%{error: "invalid id"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  # Protocol rev — keyset pagination. Requests without `limit` are still
  # capped at the server max (500) and gain `has_more`/`next_cursor`; old
  # plugins see a truncated-but-valid page and converge over successive
  # polls because they advance `since = server_time`.
  def changes(conn, %{"since" => since_str} = params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, since} <- parse_changes_since(since_str),
         {:ok, limit} <- parse_changes_limit(params["limit"]),
         {:ok, fields} <- parse_changes_fields(params["fields"]) do
      opts = [limit: limit, fields: fields]
      opts = if params["cursor"], do: Keyword.put(opts, :cursor, params["cursor"]), else: opts

      case Notes.list_changes_page(user, vault, since, opts) do
        {:ok, %{changes: changes, has_more: has_more, next_cursor: next_cursor}} ->
          json(conn, %{
            changes: Enum.map(changes, &change_json(&1, fields)),
            server_time: changes_server_time(changes, has_more),
            has_more: has_more,
            next_cursor: next_cursor
          })

        {:error, :invalid_cursor} ->
          conn |> put_status(400) |> json(%{error: "invalid_cursor"})
      end
    else
      {:error, :invalid_since} ->
        conn |> put_status(400) |> json(%{error: "invalid since timestamp"})

      {:error, :invalid_limit} ->
        conn |> put_status(400) |> json(%{error: "invalid_limit"})

      {:error, :invalid_fields} ->
        conn |> put_status(400) |> json(%{error: "invalid_fields"})
    end
  end

  def changes(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: since"})
  end

  # Legacy-client convergence: pre-pagination plugins advance
  # `since = server_time` after every poll. On a truncated page, "now" would
  # skip the un-fetched tail forever (silent loss) — so server_time is the
  # high-water mark this response is COMPLETE through: the last returned
  # change's updated_at when has_more, "now" otherwise. The since filter is
  # inclusive (>=), so the next poll resumes exactly at the boundary (the
  # boundary row repeats once; applies are idempotent).
  defp changes_server_time(changes, true) when changes != [] do
    changes |> List.last() |> Map.fetch!(:updated_at) |> DateTime.to_iso8601()
  end

  defp changes_server_time(_changes, _has_more) do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  @changes_max_limit 500

  defp parse_changes_since(since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, since, _offset} -> {:ok, since}
      {:error, _} -> {:error, :invalid_since}
    end
  end

  defp parse_changes_limit(nil), do: {:ok, @changes_max_limit}

  defp parse_changes_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} when n >= 1 -> {:ok, min(n, @changes_max_limit)}
      _ -> {:error, :invalid_limit}
    end
  end

  defp parse_changes_limit(_), do: {:error, :invalid_limit}

  defp parse_changes_fields(nil), do: {:ok, :all}
  defp parse_changes_fields("meta"), do: {:ok, :meta}
  defp parse_changes_fields(_), do: {:error, :invalid_fields}

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

  @batch_upsert_max 100

  def batch_upsert(conn, %{"notes" => notes}) when is_list(notes) do
    cond do
      length(notes) > @batch_upsert_max ->
        conn |> put_status(400) |> json(%{error: "too_many_notes", max: @batch_upsert_max})

      not Enum.all?(notes, &is_map/1) ->
        conn |> put_status(400) |> json(%{error: "invalid_notes"})

      true ->
        do_batch_upsert(conn, notes)
    end
  end

  def batch_upsert(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: notes"})
  end

  defp do_batch_upsert(conn, notes) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    # Per-note size gate (mirrors the single-note 413): oversized entries
    # become per-note errors instead of failing the whole batch — the other
    # 99 notes in a bulk sync shouldn't pay for one huge file.
    {sized, oversized} =
      notes
      |> Enum.with_index()
      |> Enum.split_with(fn {note, _idx} ->
        byte_size(note["content"] || "") <= @max_note_bytes
      end)

    case Notes.batch_upsert_notes(user, vault, Enum.map(sized, &elem(&1, 0))) do
      {:ok, %{results: results}} ->
        by_index =
          sized
          |> Enum.map(&elem(&1, 1))
          |> Enum.zip(Enum.map(results, &batch_result_json/1))
          |> Map.new()

        oversized_by_index =
          Map.new(oversized, fn {note, idx} ->
            {idx,
             %{
               path: note["path"] || "",
               status: "error",
               errors: %{content: ["exceeds maximum size of 10MB"]}
             }}
          end)

        merged =
          Enum.map(0..(length(notes) - 1), fn idx ->
            by_index[idx] || oversized_by_index[idx]
          end)

        body = %{results: merged}
        Engram.Idempotency.remember(conn.assigns.idempotency_key, %{status: 200, body: body})
        json(conn, body)

      {:error, {:notes_cap_reached, limit, current}} ->
        EngramWeb.LimitResponse.halt(conn, "notes_cap_exceeded", :notes_cap, limit, current)

      {:error, _reason} ->
        conn |> put_status(500) |> json(%{error: "internal"})
    end
  end

  defp batch_result_json(%{status: :ok} = result) do
    %{
      path: result.path,
      status: "ok",
      id: result.id,
      version: result.version,
      content_hash: result.content_hash,
      server_path: result.server_path
    }
  end

  defp batch_result_json(%{status: :conflict} = result) do
    %{path: result.path, status: "conflict", server_note: note_json(result.server_note)}
  end

  defp batch_result_json(%{status: :error} = result) do
    %{path: result.path, status: "error", errors: batch_errors_json(result.errors)}
  end

  defp batch_errors_json(%Ecto.Changeset{} = changeset), do: format_errors(changeset)
  defp batch_errors_json(other), do: other

  def batch_delete(conn, %{"ids" => ids}) when is_list(ids) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case parse_int_list(ids) do
      :error ->
        conn |> put_status(400) |> json(%{error: "invalid_ids"})

      {:ok, ids} ->
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
    end
  end

  def batch_delete(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: ids"})
  end

  def batch_move(conn, %{"ids" => ids, "target_folder_id" => tgt}) when is_list(ids) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, ids} <- parse_int_list(ids),
         {:ok, tgt} <- parse_move_target(tgt) do
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
      # Protocol rev — clients store the server hash per path so hash-only
      # broadcasts / fields=meta pages can be compared without refetching.
      # The hash is keyed server-side (HMAC); clients treat it as opaque.
      content_hash: note.content_hash,
      mtime: note.mtime,
      updated_at: note.updated_at
    }
  end

  defp change_json(change, :meta) do
    %{
      id: change.id,
      path: change.path,
      title: change.title,
      folder: change.folder || "",
      tags: change.tags || [],
      version: change.version,
      mtime: change.mtime,
      content_hash: change.content_hash,
      deleted: change.deleted,
      updated_at: change.updated_at
    }
  end

  defp change_json(change, :all) do
    change
    |> change_json(:meta)
    |> Map.put(:content, change.content || "")
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

  defp parse_int(s) when is_binary(s), do: Ecto.UUID.cast(s)
  defp parse_int(_), do: :error

  # Move target is either a folder-marker UUID or the literal "root" sentinel
  # (vault root — no marker). "root" must bypass the UUID cast.
  defp parse_move_target("root"), do: {:ok, "root"}
  defp parse_move_target(s) when is_binary(s), do: parse_int(s)
  defp parse_move_target(_), do: :error

  defp broadcast_batch(user, vault, payload) do
    EngramWeb.Endpoint.broadcast!(
      "sync:#{user.id}:#{vault.id}",
      "notes.batch",
      payload
    )
  end
end
