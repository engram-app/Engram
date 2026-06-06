defmodule Engram.Accounts.Lifecycle do
  @moduledoc """
  Soft + hard account-delete pipeline shared by user-initiated delete,
  Clerk `user.deleted` webhook, and the inactivity sweep.

  Soft = reversible (sets `deleted_at`, drops Qdrant, revokes tokens, emails).
  Hard = cascade purge of every store (sessions, Paddle, Qdrant, S3, PG, Clerk).

  Both are idempotent.
  """

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Crypto.HMAC
  alias Engram.Mailer
  alias Engram.Repo
  alias Engram.Vector.Qdrant

  require Logger

  @type reason :: :user | :clerk | :inactivity

  @doc """
  Soft-deletes a user: drops Qdrant points, stamps `users.deleted_at`,
  revokes refresh tokens, and emails the account-deleted notice.

  No-op on a user that already carries `deleted_at` — idempotent.

  Qdrant failures are best-effort: logged and swallowed. The user's
  vector data becomes unreachable anyway once `deleted_at` is set, and
  the hard-delete sweep wipes it later either way.
  """
  @spec soft_delete(User.t(), reason()) :: :ok
  def soft_delete(%User{deleted_at: %DateTime{}}, _reason), do: :ok

  def soft_delete(%User{} = user, reason) do
    _ = drop_qdrant_for_user(user)

    user
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
    |> Repo.update!(skip_tenant_check: true)

    Accounts.revoke_all_user_tokens(user)
    _ = Mailer.send_account_deleted_notice(user)

    :telemetry.execute(
      [:engram, :account, :soft_deleted],
      %{count: 1},
      %{user_id_hmac: HMAC.hash_user_id(user.id), reason: reason}
    )

    :ok
  end

  defp drop_qdrant_for_user(user) do
    case Qdrant.delete_by_user(user.id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Qdrant clear failed during soft-delete",
          user_id: user.id,
          reason: inspect(reason)
        )

        :error
    end
  rescue
    e ->
      Logger.error("Qdrant clear raised during soft-delete",
        user_id: user.id,
        exception: inspect(e)
      )

      :error
  end
end
