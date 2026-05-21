defmodule EngramWeb.SyncChannelTest do
  use EngramWeb.ChannelCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Notes
  alias Engram.Repo

  setup do
    user = insert(:user)
    other_user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, other_user} = Engram.Crypto.ensure_user_dek(other_user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "channel-test")

    socket = user_socket(user)
    {:ok, _, socket} = join_sync(socket, user, vault)

    %{socket: socket, user: user, vault: vault, other_user: other_user, api_key: api_key}
  end

  # ---------------------------------------------------------------------------
  # Connection & auth
  # ---------------------------------------------------------------------------

  describe "connect/3" do
    test "accepts valid API key" do
      user = insert(:user)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test")

      assert {:ok, socket} =
               connect(EngramWeb.UserSocket, %{"token" => api_key})

      assert socket.assigns.current_user.id == user.id
    end

    test "rejects missing token" do
      assert :error = connect(EngramWeb.UserSocket, %{})
    end

    test "rejects invalid token" do
      assert :error = connect(EngramWeb.UserSocket, %{"token" => "bad_token"})
    end
  end

  describe "join/3" do
    test "accepts join for own user_id and vault", %{user: user, vault: vault} do
      socket = user_socket(user)
      assert {:ok, _, _} = join_sync(socket, user, vault)
    end

    test "rejects join for another user's channel", %{user: user, other_user: other_user} do
      other_vault = insert(:vault, user: other_user, is_default: true)
      socket = user_socket(user)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.SyncChannel,
                 "sync:#{other_user.id}:#{other_vault.id}"
               )
    end

    test "rejects join for vault belonging to another user", %{user: user, other_user: other_user} do
      other_vault = insert(:vault, user: other_user, is_default: true)
      socket = user_socket(user)

      assert {:error, %{reason: "vault_not_found"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{other_vault.id}"
               )
    end

    test "rejects join with invalid vault_id", %{user: user} do
      socket = user_socket(user)

      assert {:error, %{reason: "invalid_vault_id"}} =
               subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{user.id}:notanint")
    end

    test "rejects topic without vault_id", %{user: user} do
      socket = user_socket(user)

      assert {:error, %{reason: "invalid_topic"}} =
               subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{user.id}")
    end

    # Pricing v2 §G — Free's realtime_sync_enabled is false; bypass the
    # ChannelCase helper that grants the override and confirm reject.
    # The gate is env-flag-gated so we flip it on for this test only.
    test "rejects Free user without realtime_sync override (gate on)" do
      prev = Application.get_env(:engram, :realtime_sync_gate_enabled)
      Application.put_env(:engram, :realtime_sync_gate_enabled, true)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:engram, :realtime_sync_gate_enabled),
          else: Application.put_env(:engram, :realtime_sync_gate_enabled, prev)
      end)

      free_user = insert(:user)
      {:ok, free_user} = Engram.Crypto.ensure_user_dek(free_user)
      vault = insert(:vault, user: free_user, is_default: true)

      socket =
        Phoenix.ChannelTest.socket(EngramWeb.UserSocket, "user_#{free_user.id}", %{
          current_user: free_user,
          current_api_key: nil
        })

      assert {:error, %{reason: "channel_forbidden_on_plan"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.SyncChannel,
                 "sync:#{free_user.id}:#{vault.id}"
               )
    end
  end

  # ---------------------------------------------------------------------------
  # API key vault restrictions on join
  # ---------------------------------------------------------------------------

  describe "join/3 with restricted API key" do
    test "restricted key can join its authorized vault", %{user: user, vault: vault} do
      {:ok, _raw, api_key_record} = Engram.Accounts.create_api_key(user, "restricted-chan")

      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: api_key_record.id, vault_id: vault.id}
      ])

      socket = user_socket(user, api_key_record)
      assert {:ok, _, _} = join_sync(socket, user, vault)
    end

    test "restricted key cannot join unauthorized vault", %{user: user, vault: vault} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, vault_b} = Engram.Vaults.create_vault(user, %{name: "Vault B"})
      {:ok, _raw, api_key_record} = Engram.Accounts.create_api_key(user, "restricted-chan2")

      # Only grant access to vault_b — NOT the default vault
      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: api_key_record.id, vault_id: vault_b.id}
      ])

      # Try to join the default vault (which the key does NOT have access to)
      socket = user_socket(user, api_key_record)

      assert {:error, %{reason: "api_key_vault_forbidden"}} =
               subscribe_and_join(
                 socket,
                 EngramWeb.SyncChannel,
                 "sync:#{user.id}:#{vault.id}"
               )
    end

    test "restricted key on topic without vault_id gets invalid_topic", %{user: user} do
      {:ok, _raw, api_key_record} = Engram.Accounts.create_api_key(user, "restricted-compat")
      socket = user_socket(user, api_key_record)

      assert {:error, %{reason: "invalid_topic"}} =
               subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{user.id}")
    end

    test "unrestricted key (no api_key_vaults rows) can join any vault", %{
      user: user,
      vault: vault
    } do
      {:ok, _raw, api_key_record} = Engram.Accounts.create_api_key(user, "unrestricted-chan")

      socket = user_socket(user, api_key_record)
      assert {:ok, _, _} = join_sync(socket, user, vault)
    end
  end

  # ---------------------------------------------------------------------------
  # push_note
  # ---------------------------------------------------------------------------

  describe "push_note" do
    test "creates note and replies with note metadata", %{socket: socket} do
      ref =
        push(socket, "push_note", %{
          "path" => "Test/Hello.md",
          "content" => "# Hello\n\nWorld.",
          "mtime" => 1_000.0
        })

      assert_reply ref, :ok, %{"note" => note, "indexing" => "queued"}
      assert note["path"] == "Test/Hello.md"
      assert note["title"] == "Hello"
      assert note["version"] == 1
    end

    test "broadcasts note_changed to other subscribers", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      # Second subscriber on the same channel topic
      other_socket = user_socket(user)
      {:ok, _, _} = join_sync(other_socket, user, vault)

      push(socket, "push_note", %{
        "path" => "Test/Shared.md",
        "content" => "# Shared",
        "mtime" => 1_000.0
      })

      assert_broadcast "note_changed", %{
        "event_type" => "upsert",
        "path" => "Test/Shared.md",
        "content" => "# Shared",
        "title" => "Shared"
      }
    end

    test "broadcasts note_changed to sender (Endpoint.broadcast semantics)", %{socket: socket} do
      push(socket, "push_note", %{
        "path" => "Test/Echo.md",
        "content" => "# Echo",
        "mtime" => 1_000.0
      })

      # Notes context uses Endpoint.broadcast (not broadcast_from!), so sender
      # also receives the note_changed event. Clients should deduplicate by path/version.
      assert_push "note_changed", %{
        "event_type" => "upsert",
        "path" => "Test/Echo.md",
        "content" => "# Echo"
      }
    end

    test "sanitizes path in push_note", %{socket: socket} do
      ref =
        push(socket, "push_note", %{
          "path" => "Test/Dirty?.md",
          "content" => "# Dirty",
          "mtime" => 1_000.0
        })

      assert_reply ref, :ok, %{"note" => note}
      assert note["path"] == "Test/Dirty.md"
    end

    test "returns error for missing path", %{socket: socket} do
      ref = push(socket, "push_note", %{"content" => "# No path", "mtime" => 1_000.0})
      assert_reply ref, :error, %{"reason" => _}
    end
  end

  # ---------------------------------------------------------------------------
  # delete_note
  # ---------------------------------------------------------------------------

  describe "delete_note" do
    test "soft-deletes note and replies ok", %{socket: socket, user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/ToDelete.md",
        "content" => "# Delete me",
        "mtime" => 1_000.0
      })

      ref = push(socket, "delete_note", %{"path" => "Test/ToDelete.md"})
      assert_reply ref, :ok, %{"deleted" => true}

      assert {:error, :not_found} = Notes.get_note(user, vault, "Test/ToDelete.md")
    end

    test "broadcasts note_changed with event_type delete", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Gone.md",
        "content" => "# Gone",
        "mtime" => 1_000.0
      })

      push(socket, "delete_note", %{"path" => "Test/Gone.md"})

      assert_broadcast "note_changed", %{
        "event_type" => "delete",
        "path" => "Test/Gone.md"
      }

      # Notes context broadcasts via Endpoint.broadcast (includes sender)
    end

    test "is idempotent for nonexistent path", %{socket: socket} do
      ref = push(socket, "delete_note", %{"path" => "Fake/Note.md"})
      assert_reply ref, :ok, %{"deleted" => true}
    end
  end

  # ---------------------------------------------------------------------------
  # rename_note
  # ---------------------------------------------------------------------------

  describe "rename_note" do
    test "renames note and replies with updated note", %{socket: socket, user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Original.md",
        "content" => "# Original",
        "mtime" => 1_000.0
      })

      ref =
        push(socket, "rename_note", %{
          "old_path" => "Test/Original.md",
          "new_path" => "Test/Renamed.md"
        })

      assert_reply ref, :ok, %{"note" => note}
      assert note["path"] == "Test/Renamed.md"
    end

    test "broadcasts note_changed for old and new path", %{
      socket: socket,
      user: user,
      vault: vault
    } do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/MoveSrc.md",
        "content" => "# Move",
        "mtime" => 1_000.0
      })

      push(socket, "rename_note", %{
        "old_path" => "Test/MoveSrc.md",
        "new_path" => "Test/MoveDst.md"
      })

      # Notes context broadcasts both events via Endpoint.broadcast
      assert_broadcast "note_changed", %{"event_type" => "delete", "path" => "Test/MoveSrc.md"}
      assert_broadcast "note_changed", %{"event_type" => "upsert", "path" => "Test/MoveDst.md"}
    end

    test "returns error for nonexistent source", %{socket: socket} do
      ref =
        push(socket, "rename_note", %{
          "old_path" => "Nope/Missing.md",
          "new_path" => "Nope/New.md"
        })

      assert_reply ref, :error, %{"reason" => _}
    end
  end

  # ---------------------------------------------------------------------------
  # pull_changes
  # ---------------------------------------------------------------------------

  describe "pull_changes" do
    test "returns changes since timestamp", %{socket: socket, user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Recent.md",
        "content" => "# Recent",
        "mtime" => 1_000.0
      })

      ref = push(socket, "pull_changes", %{"since" => "2020-01-01T00:00:00Z"})

      assert_reply ref, :ok, %{"changes" => changes, "server_time" => _}
      assert Enum.any?(changes, &(&1["path"] == "Test/Recent.md"))
    end

    test "returns empty changes for future timestamp", %{socket: socket} do
      ref = push(socket, "pull_changes", %{"since" => "2099-01-01T00:00:00Z"})
      assert_reply ref, :ok, %{"changes" => []}
    end

    test "returns error for invalid timestamp", %{socket: socket} do
      ref = push(socket, "pull_changes", %{"since" => "not-a-date"})
      assert_reply ref, :error, %{"reason" => _}
    end

    test "returns error when since is missing", %{socket: socket} do
      ref = push(socket, "pull_changes", %{})
      assert_reply ref, :error, %{"reason" => _}
    end
  end

  # ---------------------------------------------------------------------------
  # T3.7 — RotationGate: all 4 handlers blocked while rotation is in progress
  # ---------------------------------------------------------------------------

  describe "rotation lock (T3.7)" do
    setup %{user: user} do
      # Set lock directly on the DB row — do NOT use RotationLock.acquire/2 because
      # the advisory lock does not survive across a Sandbox checkout in non-async tests.
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      :ok
    end

    test "push_note replies rotation_in_progress when user is locked", %{socket: socket} do
      ref =
        push(socket, "push_note", %{
          "path" => "Lock/Test.md",
          "content" => "# Locked",
          "mtime" => 1_000.0
        })

      assert_reply ref, :error, %{reason: "rotation_in_progress", retry_after_seconds: 60}
    end

    test "delete_note replies rotation_in_progress when user is locked", %{socket: socket} do
      ref = push(socket, "delete_note", %{"path" => "Lock/Test.md"})
      assert_reply ref, :error, %{reason: "rotation_in_progress", retry_after_seconds: 60}
    end

    test "rename_note replies rotation_in_progress when user is locked", %{socket: socket} do
      ref =
        push(socket, "rename_note", %{
          "old_path" => "Lock/Old.md",
          "new_path" => "Lock/New.md"
        })

      assert_reply ref, :error, %{reason: "rotation_in_progress", retry_after_seconds: 60}
    end

    test "pull_changes replies rotation_in_progress when user is locked", %{socket: socket} do
      ref = push(socket, "pull_changes", %{"since" => "2020-01-01T00:00:00Z"})
      assert_reply ref, :error, %{reason: "rotation_in_progress", retry_after_seconds: 60}
    end
  end
end
