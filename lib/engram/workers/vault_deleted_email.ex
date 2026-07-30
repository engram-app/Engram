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

        # The section goes in the hash and `highlight` stays in the real query
        # string: a query placed inside a hash is never parsed by
        # location.search, so the SPA would never see it there.
        manage_url = EngramWeb.Endpoint.url() <> "/?highlight=#{vault.id}#settings/vaults"

        _ =
          Mailer.send_vault_deletion_notice(user, vault_name(vault, user), purge_date, manage_url)

        :ok
    end
  end

  defp vault_name(vault, user) do
    with {:ok, decrypted} <- Crypto.maybe_decrypt_vault_fields(vault, user),
         label when is_binary(label) and label != "" <- decrypted.name do
      label
    else
      _ -> vault.slug
    end
  end
end
