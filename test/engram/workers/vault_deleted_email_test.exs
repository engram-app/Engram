defmodule Engram.Workers.VaultDeletedEmailTest do
  use Engram.DataCase, async: true

  alias Engram.Vaults
  alias Engram.Workers.VaultDeletedEmail

  setup do
    user = insert(:user, email: "u@example.com")
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    %{user: user}
  end

  test "perform sends the notice for a soft-deleted vault", %{user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "Gone"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    job = %Oban.Job{args: %{"user_id" => user.id, "vault_id" => v.id}}
    assert :ok = VaultDeletedEmail.perform(job)
  end

  test "perform is a no-op when the vault is missing", %{user: user} do
    job = %Oban.Job{args: %{"user_id" => user.id, "vault_id" => 999_999}}
    assert :ok = VaultDeletedEmail.perform(job)
  end
end
