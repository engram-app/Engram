defmodule Engram.Accounts.ProfileTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Accounts

  describe "update_profile/2" do
    test "updates display_name" do
      {:ok, user} = Accounts.create_user_with_password("alice@example.com", "password123")

      assert {:ok, updated} = Accounts.update_profile(user, %{display_name: "Alice"})
      assert updated.display_name == "Alice"
    end

    test "trims whitespace and clears with empty string" do
      {:ok, user} = Accounts.create_user_with_password("bob@example.com", "password123")

      {:ok, named} = Accounts.update_profile(user, %{display_name: "  Bob  "})
      assert named.display_name == "Bob"

      {:ok, cleared} = Accounts.update_profile(named, %{display_name: ""})
      assert is_nil(cleared.display_name)
    end

    test "rejects display_name longer than 80 chars" do
      {:ok, user} = Accounts.create_user_with_password("cara@example.com", "password123")
      too_long = String.duplicate("a", 81)

      assert {:error, %Ecto.Changeset{} = cs} =
               Accounts.update_profile(user, %{display_name: too_long})

      assert %{display_name: ["should be at most 80 character(s)"]} = errors_on(cs)
    end

    test "no-op when display_name is absent from attrs" do
      {:ok, user} = Accounts.create_user_with_password("dan@example.com", "password123")
      {:ok, named} = Accounts.update_profile(user, %{display_name: "Dan"})
      assert named.display_name == "Dan"

      {:ok, untouched} = Accounts.update_profile(named, %{})
      assert untouched.display_name == "Dan"

      {:ok, still_untouched} = Accounts.update_profile(untouched, %{unrelated: "ignored"})
      assert still_untouched.display_name == "Dan"
    end
  end

  describe "active_admin_count/0" do
    test "counts only admins that are not deleted or suspended" do
      {:ok, _bootstrap_admin} =
        Accounts.create_user_with_password("admin1@example.com", "password123")

      # Subsequent users default to member.
      {:ok, _member} = Accounts.create_user_with_password("member@example.com", "password123")

      assert Accounts.active_admin_count() == 1
    end

    test "ignores soft-deleted admins" do
      {:ok, admin} = Accounts.create_user_with_password("admin2@example.com", "password123")

      admin
      |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
      |> Engram.Repo.update!(skip_tenant_check: true)

      assert Accounts.active_admin_count() == 0
    end

    test "ignores suspended admins" do
      {:ok, admin} = Accounts.create_user_with_password("susp-admin@example.com", "password123")

      admin
      |> Ecto.Changeset.change(%{suspended_at: DateTime.utc_now()})
      |> Engram.Repo.update!(skip_tenant_check: true)

      assert Accounts.active_admin_count() == 0
    end
  end

  describe "delete_self/2 — immediate cascade" do
    setup :set_mox_from_context
    setup :verify_on_exit!

    setup do
      # `create_user_with_password` assigns a Clerk-style external_id, so
      # `Lifecycle.hard_delete` calls `Clerk.ApiMock.delete_user/1` on the
      # cascade. Stub it so any number of calls return :ok without per-test
      # expectations. Paddle is only invoked if a subscription row exists.
      stub(Engram.Auth.Clerk.ApiMock, :delete_user, fn _ -> :ok end)
      :ok
    end

    test "now hard-deletes the user (no 30-day wait)" do
      {:ok, _admin} = Accounts.create_user_with_password("keep-admin@example.com", "password123")
      {:ok, user} = Accounts.create_user_with_password("victim@example.com", "password123")

      {:ok, _raw, _record} = Accounts.create_refresh_token(user)
      {:ok, _key, _record} = Accounts.create_api_key(user, "ci")

      assert :ok = Accounts.delete_self(user, "password123")

      refute Engram.Repo.get(Engram.Accounts.User, user.id, skip_tenant_check: true)
    end

    test "force-disconnects live sockets" do
      {:ok, _admin} = Accounts.create_user_with_password("keep-admin2@example.com", "password123")
      {:ok, user} = Accounts.create_user_with_password("kick@example.com", "password123")

      topic = "user_socket:#{user.id}"
      EngramWeb.Endpoint.subscribe(topic)

      assert :ok = Accounts.delete_self(user, "password123")

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "still enforces password gate" do
      {:ok, _admin} = Accounts.create_user_with_password("admin3@example.com", "password123")
      {:ok, user} = Accounts.create_user_with_password("wrong@example.com", "password123")

      assert {:error, :invalid_password} = Accounts.delete_self(user, "nope")

      # Password-gate failure must NOT touch the user row.
      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      assert is_nil(reloaded.deleted_at)
    end

    test "still enforces last-admin guard" do
      {:ok, admin} = Accounts.create_user_with_password("solo-admin@example.com", "password123")

      assert {:error, :last_admin} = Accounts.delete_self(admin, "password123")

      # Guard rejection must NOT touch the user row.
      reloaded = Engram.Repo.get!(Engram.Accounts.User, admin.id, skip_tenant_check: true)
      assert is_nil(reloaded.deleted_at)
    end

    test "half-state recovery: already soft-deleted user can retry without password" do
      {:ok, _admin} =
        Accounts.create_user_with_password("keep-admin-hsr@example.com", "password123")

      {:ok, user} = Accounts.create_user_with_password("stuck@example.com", "password123")

      # Simulate the crash-after-soft_delete window — `verify_password` now
      # returns {:error, :deleted}, blocking retry via the password path.
      user
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Engram.Repo.update!(skip_tenant_check: true)

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)

      # Password is ignored on the recovery branch.
      assert :ok = Accounts.delete_self(reloaded, "doesnt-matter")
      refute Engram.Repo.get(Engram.Accounts.User, user.id, skip_tenant_check: true)
    end

    test "allows admin delete when another admin remains" do
      {:ok, admin_a} = Accounts.create_user_with_password("admin-a@example.com", "password123")

      {:ok, admin_b} =
        Accounts.create_user_with_password("admin-b@example.com", "password123")

      admin_b =
        admin_b
        |> Ecto.Changeset.change(%{role: "admin"})
        |> Engram.Repo.update!(skip_tenant_check: true)

      assert :ok = Accounts.delete_self(admin_a, "password123")

      refute Engram.Repo.get(Engram.Accounts.User, admin_a.id, skip_tenant_check: true)
      _ = admin_b
    end
  end
end
