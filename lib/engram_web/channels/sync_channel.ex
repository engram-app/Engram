defmodule EngramWeb.SyncChannel do
  @moduledoc """
  Per-user, per-vault WebSocket channel for bidirectional note sync.

  Topic: "sync:{user_id}:{vault_id}"
  Auth:  socket.assigns.current_user must match user_id; vault must belong to that user.

  Client → Server events: push_note, delete_note, rename_note, pull_changes
  Server → Client broadcasts: note_changed
  """

  use Phoenix.Channel

  alias Engram.Crypto.RotationGate
  alias Engram.{Notes, Vaults}
  alias EngramWeb.Presence

  # ---------------------------------------------------------------------------
  # Join
  # ---------------------------------------------------------------------------

  @impl true
  def join("sync:" <> ids, params, socket) do
    do_join(ids, params, socket, socket.assigns.current_user)
  end

  defp do_join(ids, params, socket, user) do
    case String.split(ids, ":") do
      [user_id_str, vault_id_str] ->
        if to_string(user.id) == user_id_str do
          resolve_vault_and_join(vault_id_str, params, socket, user)
        else
          {:error, %{reason: "unauthorized"}}
        end

      _ ->
        {:error, %{reason: "invalid_topic"}}
    end
  end

  defp resolve_vault_and_join(vault_id_str, params, socket, user) do
    case Ecto.UUID.cast(vault_id_str) do
      {:ok, vault_id} ->
        case Vaults.get_vault(user, vault_id) do
          {:ok, vault} -> attach_vault_to_socket(vault, params, socket)
          {:error, _} -> {:error, %{reason: "vault_not_found"}}
        end

      :error ->
        {:error, %{reason: "invalid_vault_id"}}
    end
  end

  defp attach_vault_to_socket(vault, params, socket) do
    case check_api_key_access(socket, vault) do
      :ok ->
        socket = assign(socket, :vault, vault)
        send(self(), {:after_join, params})
        {:ok, %{reconnect_jitter_max_ms: reconnect_jitter_max_ms()}, socket}

      :forbidden ->
        {:error, %{reason: "api_key_vault_forbidden"}}
    end
  end

  defp reconnect_jitter_max_ms do
    Application.get_env(:engram, :reconnect_jitter_max_ms, 5_000)
  end

  @impl true
  def handle_info({:after_join, params}, socket) do
    device_id = Map.get(params, "device_id", "unknown")
    vault_id = socket.assigns.vault.id

    {:ok, _} =
      Presence.track(socket, device_id, %{
        joined_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        vault_id: vault_id
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # push_note
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("push_note", params, socket) do
    span_sync(:push_note, fn -> do_push_note(params, socket) end)
  end

  # ---------------------------------------------------------------------------
  # delete_note
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("delete_note", %{"path" => path}, socket) do
    span_sync(:delete_note, fn -> do_delete_note(path, socket) end)
  end

  # ---------------------------------------------------------------------------
  # rename_note
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("rename_note", %{"old_path" => old_path, "new_path" => new_path}, socket) do
    span_sync(:rename_note, fn -> do_rename_note(old_path, new_path, socket) end)
  end

  # ---------------------------------------------------------------------------
  # pull_changes
  # ---------------------------------------------------------------------------

  # Removed op (#862): the handler was unbounded — it loaded + decrypted the
  # entire vault change set (Pro = uncapped) into ONE channel frame. No client
  # ever shipped calling it (plugin + SPA use the keyset-paginated HTTP feed
  # at GET /api/sync/changes), so it goes away rather than growing pagination.
  # The stub keeps a stray legacy caller from crashing the channel.
  @impl true
  def handle_in("pull_changes", _params, socket) do
    {:reply, {:error, %{"reason" => "gone", "use" => "GET /api/sync/changes"}}, socket}
  end

  # ---------------------------------------------------------------------------
  # Per-op implementations
  # ---------------------------------------------------------------------------

  defp do_push_note(params, socket) do
    # T3.7 — re-read the lock state; socket.assigns.current_user is a stale
    # snapshot from connect/3 and will not reflect a lock acquired after join.
    case RotationGate.check(socket.assigns.current_user.id) do
      {:error, :rotation_in_progress} ->
        :telemetry.execute(
          [:engram, :crypto, :rotate, :dek, :gate_blocked],
          %{count: 1},
          %{gate_path: :channel, op: :push_note}
        )

        {:reply, {:error, %{reason: "rotation_in_progress", retry_after_seconds: 60}}, socket}

      {:error, :user_not_found} ->
        {:reply, {:error, %{reason: "user_not_found"}}, socket}

      :ok ->
        user = socket.assigns.current_user
        vault = socket.assigns.vault

        # broadcast_from: the pushing socket already holds this content —
        # excluding it halves the pusher's bandwidth on bulk syncs.
        case Notes.upsert_note(user, vault, params, broadcast_from: self()) do
          {:ok, note} ->
            reply = %{
              "note" => serialize_note(note),
              "indexing" => "queued"
            }

            {:reply, {:ok, reply}, socket}

          {:error, :version_conflict, server_note} ->
            # The client pushed against a stale version. Mirror the HTTP 409
            # path: hand back the server's copy so the plugin can 3-way merge.
            # Without this clause the 3-tuple falls through to a CaseClauseError
            # and the pusher gets no reply at all.
            {:reply,
             {:error, %{reason: "version_conflict", server_note: serialize_note(server_note)}},
             socket}

          {:error, changeset} ->
            {:reply, {:error, %{"reason" => format_errors(changeset)}}, socket}
        end
    end
  end

  defp do_delete_note(path, socket) do
    # T3.7 — re-read the lock state; stale snapshot from connect/3.
    case RotationGate.check(socket.assigns.current_user.id) do
      {:error, :rotation_in_progress} ->
        :telemetry.execute(
          [:engram, :crypto, :rotate, :dek, :gate_blocked],
          %{count: 1},
          %{gate_path: :channel, op: :delete_note}
        )

        {:reply, {:error, %{reason: "rotation_in_progress", retry_after_seconds: 60}}, socket}

      {:error, :user_not_found} ->
        {:reply, {:error, %{reason: "user_not_found"}}, socket}

      :ok ->
        user = socket.assigns.current_user
        vault = socket.assigns.vault

        :ok = Notes.delete_note(user, vault, path)
        {:reply, {:ok, %{"deleted" => true}}, socket}
    end
  end

  defp do_rename_note(old_path, new_path, socket) do
    # T3.7 — re-read the lock state; stale snapshot from connect/3.
    case RotationGate.check(socket.assigns.current_user.id) do
      {:error, :rotation_in_progress} ->
        :telemetry.execute(
          [:engram, :crypto, :rotate, :dek, :gate_blocked],
          %{count: 1},
          %{gate_path: :channel, op: :rename_note}
        )

        {:reply, {:error, %{reason: "rotation_in_progress", retry_after_seconds: 60}}, socket}

      {:error, :user_not_found} ->
        {:reply, {:error, %{reason: "user_not_found"}}, socket}

      :ok ->
        user = socket.assigns.current_user
        vault = socket.assigns.vault

        case Notes.rename_note(user, vault, old_path, new_path) do
          {:ok, note} ->
            {:reply, {:ok, %{"note" => serialize_note(note)}}, socket}

          {:error, :not_found} ->
            {:reply, {:error, %{"reason" => "note not found"}}, socket}
        end
    end
  end

  # -----------------------------------------------------------------------------
  # Telemetry helpers — engram-app/engram-infra#340
  # ---------------------------------------------------------------------------

  # Wrap a sync handler in `:telemetry.span` so the PromEx Sync subscriber
  # sees per-op latency + status. Status is derived from the `{:reply,
  # {:ok | :error, _}, _}` Phoenix Channel reply tuple. NEVER include
  # user_id/vault_id/path in metadata — cardinality contract.
  defp span_sync(op, fun) when is_atom(op) and is_function(fun, 0) do
    :telemetry.span([:engram, :sync, :event], %{op: op}, fn ->
      reply = fun.()
      {reply, %{op: op, status: sync_status(reply)}}
    end)
  end

  defp sync_status({:reply, {:ok, _}, _}), do: :ok
  defp sync_status({:reply, {:error, _}, _}), do: :error
  # Default unknown reply shapes to :error, not :ok — a handler that returns
  # something unexpected (or a future reply shape we forgot to classify) must
  # not be silently counted as a success in the sync metrics.
  defp sync_status(_), do: :error

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp serialize_note(note) do
    %{
      "path" => note.path,
      "title" => note.title,
      "folder" => note.folder,
      "tags" => note.tags,
      "version" => note.version,
      "content_hash" => note.content_hash,
      "mtime" => note.mtime,
      "updated_at" => DateTime.to_iso8601(note.updated_at)
    }
  end

  defp format_errors(changeset), do: EngramWeb.format_errors(changeset)

  defp check_api_key_access(socket, vault) do
    Vaults.check_api_key_access(socket.assigns[:current_api_key], vault)
  end
end
