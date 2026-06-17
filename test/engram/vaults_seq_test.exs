defmodule Engram.VaultsSeqTest do
  use Engram.DataCase, async: true

  alias Engram.{Repo, Vaults}

  setup do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  # Note: Repo.with_tenant/2 runs inside a transaction and returns {:ok, value},
  # so the bare integer from next_seq!/1 is unwrapped here. Later write-path
  # callers invoke next_seq!/1 directly inside their own transaction and use the
  # raw integer return.
  test "next_seq! increments the vault counter and returns the new value", %{
    user: user,
    vault: vault
  } do
    {:ok, s1} = Repo.with_tenant(user.id, fn -> Vaults.next_seq!(vault.id) end)
    {:ok, s2} = Repo.with_tenant(user.id, fn -> Vaults.next_seq!(vault.id) end)
    assert is_integer(s1)
    assert s2 == s1 + 1
  end

  test "next_seq! is isolated per vault", %{user: user, vault: vault_a} do
    {:ok, vault_b} = Vaults.create_vault(user, %{name: "B"})
    {:ok, a1} = Repo.with_tenant(user.id, fn -> Vaults.next_seq!(vault_a.id) end)
    {:ok, b1} = Repo.with_tenant(user.id, fn -> Vaults.next_seq!(vault_b.id) end)
    {:ok, a2} = Repo.with_tenant(user.id, fn -> Vaults.next_seq!(vault_a.id) end)
    assert a2 == a1 + 1
    assert b1 == a1
  end
end
