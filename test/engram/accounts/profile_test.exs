defmodule Engram.Accounts.ProfileTest do
  use Engram.DataCase, async: true

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

  describe "delete_self/2" do
    test "soft-deletes member, revokes refresh tokens, deletes api keys" do
      {:ok, _admin} = Accounts.create_user_with_password("keep-admin@example.com", "password123")
      {:ok, user} = Accounts.create_user_with_password("victim@example.com", "password123")

      {:ok, _raw, _record} = Accounts.create_refresh_token(user)
      {:ok, _key, _record} = Accounts.create_api_key(user, "ci")

      assert :ok = Accounts.delete_self(user, "password123")

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      refute is_nil(reloaded.deleted_at)

      import Ecto.Query

      tokens =
        Engram.Repo.all(
          from(rt in Engram.Auth.RefreshToken,
            where: rt.user_id == ^user.id and is_nil(rt.revoked_at)
          ),
          skip_tenant_check: true
        )

      assert tokens == []

      assert Accounts.list_api_keys(reloaded) == []
    end

    test "returns :invalid_password when password is wrong" do
      {:ok, _admin} = Accounts.create_user_with_password("admin3@example.com", "password123")
      {:ok, user} = Accounts.create_user_with_password("wrong@example.com", "password123")

      assert {:error, :invalid_password} = Accounts.delete_self(user, "nope")

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      assert is_nil(reloaded.deleted_at)
    end

    test "returns :last_admin when admin is the only active admin" do
      {:ok, admin} = Accounts.create_user_with_password("solo-admin@example.com", "password123")

      assert {:error, :last_admin} = Accounts.delete_self(admin, "password123")

      reloaded = Engram.Repo.get!(Engram.Accounts.User, admin.id, skip_tenant_check: true)
      assert is_nil(reloaded.deleted_at)
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

      reloaded = Engram.Repo.get!(Engram.Accounts.User, admin_a.id, skip_tenant_check: true)
      refute is_nil(reloaded.deleted_at)
      _ = admin_b
    end
  end
end
