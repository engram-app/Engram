defmodule Engram.Accounts.Lifecycle do
  @moduledoc """
  Soft + hard account-delete pipeline shared by user-initiated delete,
  Clerk `user.deleted` webhook, and the inactivity sweep.

  Soft = reversible (sets `deleted_at`, drops Qdrant, revokes tokens, emails).
  Hard = cascade purge of every store (sessions, Paddle, Qdrant, S3, PG, Clerk).

  Both are idempotent.
  """

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Auth.SessionInvalidator
  alias Engram.Billing.Subscription
  alias Engram.Crypto.HMAC
  alias Engram.Mailer
  alias Engram.Repo
  alias Engram.Storage
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

  @doc """
  Hard-deletes a user: cascade-purges every store the account touches.

  Ordering (spec §7.2) is best-effort, not transactional — it spans Qdrant +
  S3 + Postgres + Paddle + Clerk, none of which share a commit boundary.
  `Repo.delete!` is the commitment point; everything before it is logged-and-
  continued on error, and Clerk afterward is fire-and-forget.

  Idempotent: re-entry against an already-deleted user_id short-circuits at
  the top guard (`Repo.get(User, id)` is nil → `:ok`). Re-entry against a
  still-live user re-runs the cascade — each step is itself idempotent
  (Paddle uses `idempotency_key`, Qdrant filter-delete is no-op on empty,
  S3 prefix delete is no-op on missing keys, Clerk delete returns 4xx that
  we swallow).

  Caller passes a `reason` that flows through to telemetry; the same atom
  surfaces in `[:engram, :account, :deleted]` so dashboards split
  user-initiated / Clerk-driven / inactivity sweeps without inferring.
  """
  @spec hard_delete(User.t(), reason()) :: :ok
  def hard_delete(%User{} = user, reason) do
    case Repo.get(User, user.id, skip_tenant_check: true) do
      nil -> :ok
      live_user -> do_hard_delete(live_user, reason)
    end
  end

  defp do_hard_delete(%User{} = user, reason) do
    sub = Repo.one(from(s in Subscription, where: s.user_id == ^user.id), skip_tenant_check: true)
    had_sub = not is_nil(sub && sub.paddle_subscription_id)

    # Step 0: Kick live sockets before any data wipe. Otherwise the JWT
    # cached in socket assigns keeps streaming until the connection drops.
    _ = SessionInvalidator.disconnect_user(user.id)

    # Step 1: Paddle cancel (best-effort).
    _ = cancel_paddle_subscription(user, sub)

    # Step 2: Qdrant vectors (best-effort).
    _ = drop_qdrant_for_user(user)

    # Step 3: S3 prefixes — user blobs + exports. Retry once on failure.
    _ = wipe_storage_prefix(user, "#{user.id}/")
    _ = wipe_storage_prefix(user, "exports/#{user.id}/")

    # Step 4: COMMIT POINT — Postgres cascade. Re-raise on failure; the
    # cascade is the only state-anchored signal that the user is gone, so a
    # silent swallow would hide a half-state.
    #
    # Vaults must be deleted before the user row because `notes.user_id`,
    # `attachments.user_id`, and `chunks.user_id` reference users WITHOUT
    # ON DELETE CASCADE. Deleting the user's vaults transitively cascades
    # notes/attachments/chunks (their `vault_id` FKs do cascade), clearing
    # the path for the final `Repo.delete!(user)`. Everything else hanging
    # off `users` (api_keys, subscriptions, refresh_tokens, usage_meters,
    # …) does cascade directly.
    Repo.delete_all(
      from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id),
      skip_tenant_check: true
    )

    Repo.delete!(user, skip_tenant_check: true)

    :telemetry.execute(
      [:engram, :account, :deleted],
      %{count: 1},
      %{user_id_hmac: HMAC.hash_user_id(user.id), reason: reason, had_sub: had_sub}
    )

    # Step 5: Clerk delete (saas only). Best-effort; Clerk row may outlive
    # ours. Future Clerk webhooks find_by_external_id → :user_not_found → :ok.
    _ = delete_clerk_identity(user)

    :ok
  end

  defp cancel_paddle_subscription(_user, nil), do: :ok
  defp cancel_paddle_subscription(_user, %Subscription{paddle_subscription_id: nil}), do: :ok

  defp cancel_paddle_subscription(user, %Subscription{paddle_subscription_id: sub_id}) do
    case Engram.Paddle.Client.impl().cancel_subscription(
           sub_id,
           :immediately,
           idempotency_key: "hard-delete-#{user.id}"
         ) do
      {:ok, _data} ->
        :ok

      {:error, reason} ->
        Logger.error("Paddle cancel failed during hard-delete",
          user_id: user.id,
          paddle_subscription_id: sub_id,
          reason: inspect(reason)
        )

        :error
    end
  rescue
    e ->
      Logger.error("Paddle cancel raised during hard-delete",
        user_id: user.id,
        exception: inspect(e)
      )

      :error
  end

  # Single retry on first failure. Second failure: log + continue. S3
  # lifecycle rules sweep stragglers at the per-prefix 30-day mark.
  defp wipe_storage_prefix(user, prefix) do
    case Storage.adapter().delete_prefix(prefix) do
      {:ok, _count} ->
        :ok

      {:error, first_reason} ->
        case Storage.adapter().delete_prefix(prefix) do
          {:ok, _count} ->
            Logger.warning("Storage prefix delete succeeded on retry during hard-delete",
              user_id: user.id,
              prefix: prefix,
              first_reason: inspect(first_reason)
            )

            :ok

          {:error, retry_reason} ->
            Logger.error("Storage prefix delete failed twice during hard-delete",
              user_id: user.id,
              prefix: prefix,
              first_reason: inspect(first_reason),
              retry_reason: inspect(retry_reason)
            )

            :error
        end
    end
  rescue
    e ->
      Logger.error("Storage prefix delete raised during hard-delete",
        user_id: user.id,
        prefix: prefix,
        exception: inspect(e)
      )

      :error
  end

  defp delete_clerk_identity(%User{external_id: nil}), do: :ok

  defp delete_clerk_identity(%User{external_id: external_id} = user)
       when is_binary(external_id) do
    case clerk_api().delete_user(external_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Clerk delete_user failed during hard-delete",
          user_id: user.id,
          clerk_user_id: external_id,
          reason: inspect(reason)
        )

        :error
    end
  rescue
    e ->
      Logger.error("Clerk delete_user raised during hard-delete",
        user_id: user.id,
        clerk_user_id: external_id,
        exception: inspect(e)
      )

      :error
  end

  defp clerk_api do
    Application.get_env(:engram, :clerk_api, Engram.Auth.Clerk.HttpApi)
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
