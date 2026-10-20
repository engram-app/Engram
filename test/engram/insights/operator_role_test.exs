defmodule Engram.Insights.OperatorRoleTest do
  use Engram.DataCase, async: false

  alias Engram.Accounts
  alias Engram.Insights.RoleChange
  alias Engram.Release

  defp role(user), do: Repo.reload!(user).role
  defp log, do: Repo.all(from(r in RoleChange, order_by: r.inserted_at, select: r.action))

  describe "Release.grant_operator/1 and revoke_operator/1" do
    test "grant then revoke, each logged" do
      user = insert(:user, email: "todd@example.com")

      assert :ok = Release.grant_operator(" Todd@Example.com ")
      assert role(user) == "operator"

      assert :ok = Release.revoke_operator("todd@example.com")
      assert role(user) == "member"

      assert log() == ["grant_operator", "revoke_operator"]

      assert [%RoleChange{actor_id: nil, scope: "platform", target_user_id: id} | _] =
               Repo.all(RoleChange)

      assert id == user.id
    end

    test "an unknown or deleted email changes nothing" do
      insert(:user, email: "gone@example.com", deleted_at: DateTime.utc_now())

      assert {:error, :not_found} = Release.grant_operator("nobody@example.com")
      assert {:error, :not_found} = Release.grant_operator("gone@example.com")
      assert log() == []
    end

    test "never turns an admin into an operator, nor revokes a non-operator" do
      admin = insert(:user, role: "admin")
      member = insert(:user)

      assert {:error, {:role_is, "admin"}} = Release.grant_operator(admin.email)
      assert {:error, {:role_is, "member"}} = Release.revoke_operator(member.email)
      assert role(admin) == "admin"
      assert log() == []
    end
  end

  describe "no other path grants the role" do
    test "set_role refuses operator" do
      user = insert(:user)
      assert {:error, :invalid_role} = Accounts.set_role(user, "operator")
      assert role(user) == "member"
    end

    test "a profile update ignores a role field" do
      user = insert(:user)
      {:ok, _} = Accounts.update_profile(user, %{"role" => "operator", "display_name" => "X"})
      assert role(user) == "member"
    end

    # Source lint: a changeset that casts :role is how a request body could
    # grant it. `set_role/2` (admin/member only) and Engram.Release are the
    # only writers.
    test "no changeset in lib casts :role" do
      offenders =
        for path <- Path.wildcard("lib/**/*.ex"),
            source = File.read!(path),
            Regex.match?(~r/cast\([^)]*:role\b/s, source),
            do: path

      assert offenders == []
    end
  end
end
