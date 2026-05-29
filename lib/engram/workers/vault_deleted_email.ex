defmodule Engram.Workers.VaultDeletedEmail do
  @moduledoc """
  Oban worker: emails a user that a vault was soft-deleted, with a link to the
  vault settings page (restore / purge-now). Self-host installs no-op via the
  NoOp mail provider. Sends asynchronously so the DELETE request is never
  blocked on mail delivery.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Mailer
  alias Engram.Repo
  alias Engram.Vaults.Vault

  require Logger

  @retention_days 30

  def enqueue(user_id, vault_id) do
    %{user_id: user_id, vault_id: vault_id}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id}}) do
    user = Repo.get(User, user_id, skip_tenant_check: true)
    vault = Repo.get(Vault, vault_id, skip_tenant_check: true)

    cond do
      is_nil(user) or is_nil(vault) ->
        :ok

      is_nil(vault.deleted_at) ->
        :ok

      true ->
        purge_at = DateTime.add(vault.deleted_at, @retention_days * 86_400, :second)
        purge_date = Calendar.strftime(purge_at, "%B %-d, %Y")
        manage_url = EngramWeb.Endpoint.url() <> "/settings/vaults?highlight=#{vault.id}"

        _ =
          Mailer.send_vault_deletion_notice(user, vault_name(vault, user), purge_date, manage_url)

        :ok
    end
  end

  defp vault_name(vault, user) do
    case Crypto.maybe_decrypt_vault_fields(vault, user) do
      {:ok, %{name: name}} when is_binary(name) and name != "" -> name
      _ -> vault.slug
    end
  end
end
