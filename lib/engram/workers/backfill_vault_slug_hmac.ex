defmodule Engram.Workers.BackfillVaultSlugHmac do
  @moduledoc """
  Reconciles `vaults.slug` / `slug_hmac` / `slug_suffixed` after the expand
  release (`20260926100000_add_vault_slug_hmac_expand`); see
  `Vaults.backfill_slug_hmacs/1`.

  The HMAC needs each user's DEK-derived filter key, so it cannot run in the
  migration. Daily cron over every row (not only NULL ones) so renames by
  pre-expand code during the deploy window, or after a rollback, heal too.
  Users mid-DEK-rotation are skipped and picked up next run. Daily, not
  hourly: each run unwraps every vault-owning user's DEK into the worker's
  DekCache, and the lookup switch waits for a clean run anyway.
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
    Repo.all(from(u in User, where: is_nil(u.deleted_at), order_by: u.id, select: u.id))
    |> Enum.each(&backfill_user/1)
  end

  # Each user runs in its own transaction; one user's failure (e.g. a unique
  # violation on a hand-edited slug) is logged and must not starve the rest.
  defp backfill_user(user_id) do
    case Vaults.backfill_slug_hmacs(user_id) do
      {:ok, count} when count > 0 ->
        Logger.info(
          "vault slugs reconciled",
          Metadata.with_category(:info, :crypto, user_id: user_id, reconciled: count)
        )

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "vault slug reconcile failed",
        Metadata.with_category(:warning, :crypto,
          user_id: user_id,
          reason: Metadata.safe_reason(e)
        )
      )
  end
end
