defmodule EngramWeb.UserChannelTest do
  use EngramWeb.ChannelCase, async: true

  alias Engram.{Notes, Vaults}

  setup do
    user = insert(:user)
    other_user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, other_user} = Engram.Crypto.ensure_user_dek(other_user)

    {:ok, socket} = connect_as(user)
    {:ok, _, socket} = subscribe_and_join(socket, "user:#{user.id}", %{})

    %{user: user, other_user: other_user, socket: socket}
  end

  defp connect_as(user) do
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "user-channel-test")
    connect(EngramWeb.UserSocket, %{"token" => api_key})
  end

  describe "join/3" do
    test "rejects joining another user's topic", %{other_user: other_user} do
      {:ok, socket} = connect_as(other_user)

      # other_user trying to join user1's topic — should fail. Open a fresh
      # socket scoped to the user we want to authenticate as, then attempt to
      # join the wrong topic.
      different_user = insert(:user)
      {:ok, different_user} = Engram.Crypto.ensure_user_dek(different_user)
      {:ok, foreign_socket} = connect_as(different_user)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(foreign_socket, "user:#{other_user.id}", %{})

      # silence "unused socket" warning
      _ = socket
    end
  end

  describe "vault_created broadcast" do
    test "subscriber receives vault_created when their vault is created", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "Demo"})

      assert_broadcast "vault_created", %{vault_id: vault_id}
      assert vault_id == vault.id
    end

    test "subscriber does NOT receive vault_created for another user", %{other_user: other_user} do
      {:ok, _} = Vaults.create_vault(other_user, %{name: "Other"})
      refute_broadcast "vault_created", %{}, 200
    end
  end

  describe "vault_populated broadcast" do
    test "fires when first note is upserted into an empty vault", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "Notes"})

      {:ok, _note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Welcome.md",
          "content" => "# Hi",
          "mtime" => 1_700_000_000.0
        })

      assert_broadcast "vault_populated", %{vault_id: vault_id}
      assert vault_id == vault.id
    end

    test "does NOT fire on the second note in the same vault", %{user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "Notes"})

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "First.md",
          "content" => "1",
          "mtime" => 1_700_000_000.0
        })

      assert_broadcast "vault_populated", %{}

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Second.md",
          "content" => "2",
          "mtime" => 1_700_000_001.0
        })

      refute_broadcast "vault_populated", %{}, 200
    end

    # Characterization guard: the populated check is VAULT-scoped, not
    # user-scoped. A user with an existing populated vault must still get
    # the broadcast for the first note of a NEW vault. (Protects against
    # replacing the existence probe with the per-user notes_count meter.)
    test "fires for the first note of a second vault even when another vault has notes",
         %{user: user} do
      # Free tier caps vaults at 1 — lift it so this user can hold two.
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})

      {:ok, vault_a} = Vaults.create_vault(user, %{name: "A"})

      {:ok, _} =
        Notes.upsert_note(user, vault_a, %{
          "path" => "Existing.md",
          "content" => "old",
          "mtime" => 1_700_000_000.0
        })

      assert_broadcast "vault_populated", %{}

      {:ok, vault_b} = Vaults.create_vault(user, %{name: "B"})

      {:ok, _} =
        Notes.upsert_note(user, vault_b, %{
          "path" => "Fresh.md",
          "content" => "new",
          "mtime" => 1_700_000_001.0
        })

      assert_broadcast "vault_populated", %{vault_id: vault_b_id}
      assert vault_b_id == vault_b.id
    end
  end
end
