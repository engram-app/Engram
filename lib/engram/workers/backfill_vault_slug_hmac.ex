defmodule Engram.Workers.BackfillVaultSlugHmac do
  @moduledoc """
  Reconciles `vaults.slug` / `slug_hmac` / `slug_suffixed` after the expand
  release (`20260926100000_add_vault_slug_hmac_expand`); see
  `Vaults.backfill_slug_hmacs/1`.

  The HMAC needs each user's DEK-derived filter key, so it cannot run in the
  migration. Hourly cron over every row (not only NULL ones) so renames by
  pre-expand code during the deploy window, or after a rollback, heal too.
  Users mid-DEK-rotation are skipped and picked up next run.
  Removed with the contract release that drops `vaults.slug`.
  """
  use Oban.Worker, queue: :crypto_backfill, max_attempts: 3, unique: [period: 3600]

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Vaults

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(60)

  @impl Oban.Worker
  def perform(_job) do
    # `users` is not RLS-scoped; the per-user vault work runs under with_tenant.
    Repo.all(from(u in User, where: is_nil(u.deleted_at)))
    |> Enum.each(&backfill_user/1)
  end

  defp backfill_user(user) do
    case Vaults.backfill_slug_hmacs(user) do
      {:ok, count} when count > 0 ->
        Logger.info(
          "vault slugs reconciled",
          Metadata.with_category(:info, :crypto, reconciled: count)
        )

      _ ->
        :ok
    end
  end
end
