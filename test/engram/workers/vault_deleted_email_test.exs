defmodule Engram.Workers.VaultDeletedEmailTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Repo
  alias Engram.Vaults
  alias Engram.Vaults.Vault
  alias Engram.Workers.VaultDeletedEmail

  setup :verify_on_exit!

  setup do
    prev_provider = Application.get_env(:engram, :email_provider)
    Application.put_env(:engram, :email_provider, Engram.Email.ProviderMock)

    on_exit(fn ->
      if is_nil(prev_provider),
        do: Application.delete_env(:engram, :email_provider),
        else: Application.put_env(:engram, :email_provider, prev_provider)
    end)

    user = insert(:user, email: "u@example.com")
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    %{user: user}
  end

  test "perform sends the notice for a soft-deleted vault", %{user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "Gone"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    expect(Engram.Email.ProviderMock, :send, 1, fn to, subject, _html, _opts ->
      assert to == "u@example.com"
      assert subject =~ "vault was deleted"
      :ok
    end)

    job = %Oban.Job{args: %{"user_id" => user.id, "vault_id" => v.id}}
    assert :ok = VaultDeletedEmail.perform(job)
  end

  test "perform is a no-op when the vault was restored before send", %{user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "Restored"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    # Restore the vault (clear deleted_at) before the job runs.
    {1, _} =
      Repo.update_all(
        from(vault in Vault, where: vault.id == ^v.id),
        [set: [deleted_at: nil]],
        skip_tenant_check: true
      )

    # No expect/0 set → if the provider is called, Mox raises on verify.
    job = %Oban.Job{args: %{"user_id" => user.id, "vault_id" => v.id}}
    assert :ok = VaultDeletedEmail.perform(job)
  end

  test "perform is a no-op when the vault is missing", %{user: user} do
    job = %Oban.Job{args: %{"user_id" => user.id, "vault_id" => Ecto.UUID.generate()}}
    assert :ok = VaultDeletedEmail.perform(job)
  end
end
