defmodule Engram.AccountsAdminTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Accounts

  test "list_users/0 returns non-deleted users" do
    a = insert(:user, role: "admin")
    m = insert(:user, role: "member")
    ids = Accounts.list_users() |> Enum.map(& &1.id)
    assert a.id in ids and m.id in ids
  end

  test "set_role/2 promotes and demotes" do
    _other_admin = insert(:user, role: "admin")
    m = insert(:user, role: "member")
    assert {:ok, u} = Accounts.set_role(m, "admin")
    assert u.role == "admin"
    assert {:ok, u2} = Accounts.set_role(u, "member")
    assert u2.role == "member"
  end

  test "set_role/2 refuses to demote the last admin" do
    admin = insert(:user, role: "admin")
    assert {:error, :last_admin} = Accounts.set_role(admin, "member")
  end

  test "suspend/1 and unsuspend/1 toggle suspended_at" do
    m = insert(:user, role: "member")
    assert {:ok, s} = Accounts.suspend(m)
    refute is_nil(s.suspended_at)
    assert {:ok, u} = Accounts.unsuspend(s)
    assert is_nil(u.suspended_at)
  end

  test "suspend/1 refuses the last admin" do
    admin = insert(:user, role: "admin")
    assert {:error, :last_admin} = Accounts.suspend(admin)
  end

  test "soft_delete_user/1 sets deleted_at and refuses last admin" do
    admin = insert(:user, role: "admin")
    m = insert(:user, role: "member")
    assert {:ok, d} = Accounts.soft_delete_user(m)
    refute is_nil(d.deleted_at)
    assert {:error, :last_admin} = Accounts.soft_delete_user(admin)
  end

  test "suspend/1 force-disconnects live sockets" do
    _admin = insert(:user, role: "admin")
    m = insert(:user, role: "member")
    topic = "user_socket:#{m.id}"
    EngramWeb.Endpoint.subscribe(topic)

    assert {:ok, _} = Accounts.suspend(m)

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  test "suspend/1 does NOT broadcast disconnect when rolled back as last_admin" do
    admin = insert(:user, role: "admin")
    topic = "user_socket:#{admin.id}"
    EngramWeb.Endpoint.subscribe(topic)

    assert {:error, :last_admin} = Accounts.suspend(admin)

    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 50
  end

  test "soft_delete_user/1 force-disconnects live sockets" do
    _admin = insert(:user, role: "admin")
    m = insert(:user, role: "member")
    topic = "user_socket:#{m.id}"
    EngramWeb.Endpoint.subscribe(topic)

    assert {:ok, _} = Accounts.soft_delete_user(m)

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  # Spec §7 — admin DELETE on a user purges vault data, not just the user row.
  test "purge_user_vaults/1 enqueues a forced CleanupVault per owned vault" do
    user = insert(:user, role: "member")
    vault = insert(:vault, user: user)

    Accounts.purge_user_vaults(user)

    assert_enqueued(
      worker: Engram.Workers.CleanupVault,
      args: %{vault_id: vault.id, user_id: user.id, force: true}
    )
  end
end
