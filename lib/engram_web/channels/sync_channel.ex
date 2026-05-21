defmodule EngramWeb.SyncChannel do
  @moduledoc """
  Per-user, per-vault WebSocket channel for bidirectional note sync.

  Topic: "sync:{user_id}:{vault_id}"
  Auth:  socket.assigns.current_user must match user_id; vault must belong to that user.

  Client → Server events: push_note, delete_note, rename_note, pull_changes
  Server → Client broadcasts: note_changed
  """

  use Phoenix.Channel

  alias Engram.Billing
  alias Engram.Crypto.RotationGate
  alias Engram.{Notes, Vaults}
  alias EngramWeb.Presence

  # ---------------------------------------------------------------------------
  # Join
  # ---------------------------------------------------------------------------

  @impl true
  def join("sync:" <> ids, params, socket) do
    user = socket.assigns.current_user

    # Pricing v2 §G — Free's realtime_sync_enabled is false. Gate is
    # enforced when :realtime_sync_gate_enabled config is true (set on
    # launch day; default false so pre-v2-launch Free users keep syncing).
    if gate_enabled?() and
         Billing.effective_limit(user, :realtime_sync_enabled) == false do
      {:error, %{reason: "channel_forbidden_on_plan"}}
    else
      do_join(ids, params, socket, user)
    end
  end

  defp gate_enabled?, do: Application.get_env(:engram, :realtime_sync_gate_enabled, false)

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
    case Integer.parse(vault_id_str) do
      {vault_id, ""} ->
        case Vaults.get_vault(user, vault_id) do
          {:ok, vault} -> attach_vault_to_socket(vault, params, socket)
          {:error, _} -> {:error, %{reason: "vault_not_found"}}
        end

      _ ->
        {:error, %{reason: "invalid_vault_id"}}
    end
  end

  defp attach_vault_to_socket(vault, params, socket) do
    case check_api_key_access(socket, vault) do
      :ok ->
        socket = assign(socket, :vault, vault)
        send(self(), {:after_join, params})
        {:ok, socket}

      :forbidden ->
        {:error, %{reason: "api_key_vault_forbidden"}}
    end
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

        case Notes.upsert_note(user, vault, params) do
          {:ok, note} ->
            reply = %{
              "note" => serialize_note(note),
              "indexing" => "queued"
            }

            {:reply, {:ok, reply}, socket}

          {:error, changeset} ->
            {:reply, {:error, %{"reason" => format_errors(changeset)}}, socket}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # delete_note
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("delete_note", %{"path" => path}, socket) do
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

  # ---------------------------------------------------------------------------
  # rename_note
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("rename_note", %{"old_path" => old_path, "new_path" => new_path}, socket) do
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

  # ---------------------------------------------------------------------------
  # pull_changes
  # ---------------------------------------------------------------------------

  @impl true
  def handle_in("pull_changes", %{"since" => since_str}, socket) do
    # T3.7 — re-read the lock state; stale snapshot from connect/3. Reads are
    # also blocked: between a sweep batch writing dek_version=new and final_flip
    # invalidating the DekCache, the old DEK in cache cannot decrypt the new
    # ciphertext — reads during this window fail with :decrypt_failed.
    case RotationGate.check(socket.assigns.current_user.id) do
      {:error, :rotation_in_progress} ->
        :telemetry.execute(
          [:engram, :crypto, :rotate, :dek, :gate_blocked],
          %{count: 1},
          %{gate_path: :channel, op: :pull_changes}
        )

        {:reply, {:error, %{reason: "rotation_in_progress", retry_after_seconds: 60}}, socket}

      {:error, :user_not_found} ->
        {:reply, {:error, %{reason: "user_not_found"}}, socket}

      :ok ->
        user = socket.assigns.current_user
        vault = socket.assigns.vault

        case DateTime.from_iso8601(since_str) do
          {:ok, since, _} ->
            {:ok, changes} = Notes.list_changes(user, vault, since)

            serialized =
              Enum.map(changes, fn c ->
                %{
                  "path" => c.path,
                  "title" => c.title,
                  "folder" => c.folder,
                  "tags" => c.tags,
                  "version" => c.version,
                  "mtime" => c.mtime,
                  "deleted" => c.deleted,
                  "updated_at" => DateTime.to_iso8601(c.updated_at)
                }
              end)

            reply = %{
              "changes" => serialized,
              "server_time" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            {:reply, {:ok, reply}, socket}

          {:error, _} ->
            {:reply, {:error, %{"reason" => "invalid since timestamp"}}, socket}
        end
    end
  end

  def handle_in("pull_changes", _params, socket) do
    # T3.7 — missing `since` key; no need to gate (no DEK access before param parse).
    # The since-required check is purely structural validation — not a DEK write path.
    {:reply, {:error, %{"reason" => "since is required"}}, socket}
  end

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
