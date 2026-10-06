defmodule Engram.DataMigrations.VaultSlugHmac do
  @moduledoc """
  Clears the plaintext `vaults.slug`, first making `slug_hmac` /
  `slug_suffixed` describe the derived slug; see `Vaults.backfill_slug_hmacs/1`.

  The HMAC needs each user's DEK-derived filter key, so it cannot run in the
  migration. Done when a pass clears nothing for every user. Users with
  nothing to clear derive no key. A user mid-DEK-rotation or a failed user
  keeps it open for the next pass. Removed with the contract release that
  drops `vaults.slug`.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Vaults

  require Logger

  @impl true
  def name, do: "vault_slug_hmac"

  @impl true
  def version, do: 1

  @impl true
  def run_pass do
    # `users` is not RLS-scoped; the per-user vault work runs under with_tenant.
    Repo.all(from(u in User, where: is_nil(u.deleted_at), order_by: u.id, select: u.id))
    |> Enum.map(&backfill_user/1)
    |> Enum.all?(&(&1 == :clean))
    |> if(do: :done, else: :more)
  end

  # Each user runs in its own transaction; one user's failure (a returned
  # error such as a KMS outage or missing DEK, or a raise such as a unique
  # violation on a hand-edited slug) is logged and must not starve the rest.
  defp backfill_user(user_id) do
    case Vaults.backfill_slug_hmacs(user_id) do
      {:ok, 0} ->
        :clean

      {:ok, count} ->
        Logger.info(
          "vault slugs reconciled",
          Metadata.with_category(:info, :crypto, user_id: user_id, reconciled: count)
        )

        :changed

      {:error, :rotation_in_progress} ->
        :skipped

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

    :failed
  end
end
