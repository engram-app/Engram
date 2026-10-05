defmodule Engram.Workers.BackfillVaultSlugHmac do
  @moduledoc """
  Clears the plaintext `vaults.slug`, first making `slug_hmac` /
  `slug_suffixed` describe the derived slug; see
  `Vaults.backfill_slug_hmacs/1`.

  The HMAC needs each user's DEK-derived filter key, so it cannot run in the
  migration. Daily cron: the first run after this release clears every row;
  later runs only find rows an older release wrote during a rolling deploy or
  after a rollback. Users with nothing to clear derive no key. Users
  mid-DEK-rotation are skipped and picked up next run.
  Removed with the contract release that drops `vaults.slug`.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3600]

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

  # Each user runs in its own transaction; one user's failure (a returned
  # error such as a KMS outage or missing DEK, or a raise such as a unique
  # violation on a hand-edited slug) is logged and must not starve the rest.
  # Mid-rotation is expected and silent: the user is picked up next run.
  defp backfill_user(user_id) do
    case Vaults.backfill_slug_hmacs(user_id) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info(
          "vault slugs reconciled",
          Metadata.with_category(:info, :crypto, user_id: user_id, reconciled: count)
        )

      {:error, :rotation_in_progress} ->
        :ok

      {:error, reason} ->
        log_failure(user_id, reason)
    end
  rescue
    e -> log_failure(user_id, e)
  end

  defp log_failure(user_id, reason) do
    Logger.warning(
      "vault slug reconcile failed",
      Metadata.with_category(:warning, :crypto,
        user_id: user_id,
        reason: Metadata.safe_reason(reason)
      )
    )
  end
end
