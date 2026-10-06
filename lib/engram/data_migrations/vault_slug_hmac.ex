defmodule Engram.DataMigrations.VaultSlugHmac do
  @moduledoc """
  Clears the plaintext `vaults.slug`, first making `slug_hmac` /
  `slug_suffixed` describe the derived slug; see `Vaults.backfill_slug_hmacs/1`.

  The HMAC needs each user's DEK-derived filter key, so it cannot run in the
  migration. Done when, after a pass, no vault of a live user still holds a
  plaintext slug. A user mid-DEK-rotation, a failed user, or an undecryptable
  row keeps it open (the latter is logged each pass). Removed with the contract release that
  drops `vaults.slug`.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.DataMigrations
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
    |> Enum.each(&backfill_user/1)

    # Soft-deleted users are never visited above, so exclude them here too or
    # the migration could never close.
    if DataMigrations.any_row?(fn _repo ->
         from(v in Engram.Vaults.Vault,
           join: u in User,
           on: u.id == v.user_id and is_nil(u.deleted_at),
           where: not is_nil(v.slug),
           select: 1
         )
       end),
       do: :more,
       else: :done
  end

  # Each user runs in its own transaction; one user's failure (a returned
  # error such as a KMS outage or missing DEK, or a raise such as a unique
  # violation on a hand-edited slug) is logged and must not starve the rest.
  defp backfill_user(user_id) do
    case Vaults.backfill_slug_hmacs(user_id) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info(
          "vault slugs reconciled",
          Metadata.with_category(:info, :crypto, user_id: user_id, reconciled: count)
        )

        :ok

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

    :ok
  end
end
