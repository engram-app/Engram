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

    # `handle_out` resolves the credential's vault scope, which queries
    # `api_key_vaults` for an API-key-authed socket — from the CHANNEL process.
    Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, self(), socket.channel_pid)

    %{user: user, other_user: other_user, socket: socket}
  end

  defp connect_as(user) do
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "user-channel-test")
    connect(EngramWeb.UserSocket, %{"token" => api_key})
  end

  describe "join/3" do
    test "replies with the user's plan state" do
      free_user = insert(:user)
      {:ok, free_user} = Engram.Crypto.ensure_user_dek(free_user)
      {:ok, socket} = connect_as(free_user)

      {:ok, reply, _socket} = subscribe_and_join(socket, "user:#{free_user.id}", %{})

      assert reply.plan.tier == :free
      # Free now gets every attachment MIME type; storage quota is the lever.
      assert reply.plan.attachments_all_types == true
    end

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
      {:ok, vault, _} = Vaults.register_vault(user, "Demo", Ecto.UUID.generate())

      assert_broadcast "vault_created", %{vault_id: vault_id}
      assert vault_id == vault.id
    end

    test "subscriber does NOT receive vault_created for another user", %{other_user: other_user} do
      {:ok, _, _} = Vaults.register_vault(other_user, "Other", Ecto.UUID.generate())
      refute_broadcast "vault_created", %{}, 200
    end
  end

  describe "vault_populated broadcast" do
    test "fires when first note is upserted into an empty vault", %{user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())

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
      {:ok, vault, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())

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

      {:ok, vault_a, _} = Vaults.register_vault(user, "A", Ecto.UUID.generate())

      {:ok, _} =
        Notes.upsert_note(user, vault_a, %{
          "path" => "Existing.md",
          "content" => "old",
          "mtime" => 1_700_000_000.0
        })

      assert_broadcast "vault_populated", %{}

      {:ok, vault_b, _} = Vaults.register_vault(user, "B", Ecto.UUID.generate())

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

  # `user:` rides the same socket as `sync:` and `crdt:`, but unlike those it
  # takes no vault in its topic, so nothing about the JOIN says which vaults the
  # credential may reach. `vault_created` carries the DECRYPTED vault name and
  # `vault_populated` a vault id, so an unfiltered fan-out hands a grant scoped
  # away from a vault the name and existence of that vault.
  #
  # These assert on `assert_push`/`refute_push` (what reaches the CLIENT), not
  # `assert_broadcast` (what reaches the topic). The broadcast still happens for
  # everyone; `handle_out` is what decides per subscriber, so a test on the
  # broadcast would pass with the filter deleted.
  describe "vault scope filters what reaches a subscriber" do
    # Its own user, NOT the one from the outer setup. `assert_push`/`refute_push`
    # read the TEST process mailbox, and the outer setup already joined an
    # unrestricted socket to that user's topic — every broadcast there would
    # arrive twice and the refutes would fail on the unrestricted copy.
    setup do
      grantor = insert(:user)
      {:ok, grantor} = Engram.Crypto.ensure_user_dek(grantor)
      in_scope = insert(:vault, user: grantor)
      out_of_scope = insert(:vault, user: grantor)

      scoped =
        socket(EngramWeb.UserSocket, "grant_#{grantor.id}", %{
          current_user: grantor,
          current_api_key: nil,
          oauth_scope_vault_ids: [to_string(in_scope.id)]
        })

      {:ok, _, scoped} = subscribe_and_join(scoped, "user:#{grantor.id}", %{})

      %{grantor: grantor, scoped: scoped, in_scope: in_scope, out_of_scope: out_of_scope}
    end

    test "a scoped grant does NOT receive vault_created for a vault it cannot see", %{
      grantor: grantor,
      out_of_scope: out_of_scope
    } do
      EngramWeb.Endpoint.broadcast("user:#{grantor.id}", "vault_created", %{
        vault_id: out_of_scope.id,
        name: "Private Journal"
      })

      refute_push "vault_created", %{}, 200
    end

    test "a scoped grant DOES receive vault_created for a vault it can see", %{
      grantor: grantor,
      in_scope: in_scope
    } do
      EngramWeb.Endpoint.broadcast("user:#{grantor.id}", "vault_created", %{
        vault_id: in_scope.id,
        name: "Granted"
      })

      assert_push "vault_created", %{vault_id: pushed}
      assert pushed == in_scope.id
    end

    test "vault_populated is filtered the same way", %{
      grantor: grantor,
      out_of_scope: out_of_scope
    } do
      EngramWeb.Endpoint.broadcast("user:#{grantor.id}", "vault_populated", %{
        vault_id: out_of_scope.id
      })

      refute_push "vault_populated", %{}, 200
    end

    # Over-block guard. An unrestricted credential is the common case — the SPA
    # FTUX screen blocks on these events, and the plugin's device-flow token
    # carries no scope claim.
    test "an unrestricted credential still receives the event", %{
      grantor: grantor,
      out_of_scope: vault
    } do
      unscoped =
        socket(EngramWeb.UserSocket, "open_#{grantor.id}", %{
          current_user: grantor,
          current_api_key: nil,
          oauth_scope_vault_ids: nil
        })

      {:ok, _, _} = subscribe_and_join(unscoped, "user:#{grantor.id}", %{})

      EngramWeb.Endpoint.broadcast("user:#{grantor.id}", "vault_created", %{
        vault_id: vault.id,
        name: "Anything"
      })

      assert_push "vault_created", %{vault_id: _}
    end
  end
end
