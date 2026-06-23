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
  def soft_delete(%User{deleted_at: %DateTime{}} = user, _reason) do
    # Idempotent retry path: tokens may have been re-issued between attempts
    # (e.g. delete_self crashed after soft_delete, user retried). Revoke
    # again — `revoke_all_user_tokens` is idempotent. Skip Qdrant drop,
    # email, and telemetry; those already fired on the first call.
    Accounts.revoke_all_user_tokens(user)
    :ok
  end

  def soft_delete(%User{} = user, reason) do
    _ = drop_qdrant_for_user(user)

    user
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
    |> Repo.update!(skip_tenant_check: true)

    Accounts.revoke_all_user_tokens(user)
    _ = Mailer.send_account_deleted_notice(user, reason)

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

  Returns:
    * `:ok` — purge completed (or short-circuited on missing user).
    * `{:error, :last_admin}` — refuses to purge the last active admin.
      Caller decides what to do (user-flow: surface to UI; Clerk webhook:
      log + leave soft-deleted; inactivity sweep: log + skip).
    * `{:error, :pg_failed}` — Postgres commit point rolled back.
      State is recoverable: re-running `hard_delete` retries the cascade.
  """
  @spec hard_delete(User.t(), reason()) :: :ok | {:error, :last_admin | :pg_failed}
  def hard_delete(%User{} = user, reason) do
    case Repo.get(User, user.id, skip_tenant_check: true) do
      nil ->
        :ok

      live_user ->
        case guard_last_admin(live_user) do
          :ok -> do_hard_delete(live_user, reason)
          {:error, :last_admin} = err -> err
        end
    end
  end

  # Last-admin guard at the hard-delete commit point. Mirrors the
  # `Engram.Accounts.guard_last_admin/1` pattern, but excludes the
  # candidate from the active-admin count: `Accounts.active_admin_count/0`
  # already filters `is_nil(deleted_at)`, so a user that was soft-deleted
  # by `soft_delete/2` immediately before this call is correctly skipped.
  # The guard then asks the right question — "would purging this user
  # leave zero active admins?" — without needing to inspect the
  # candidate's own state.
  #
  # Without this, hard_delete (now the commit point for Clerk + delete_self
  # + inactivity) could purge the last admin and leave the instance
  # unrecoverable.
  defp guard_last_admin(%User{role: "admin", deleted_at: nil}) do
    # Live admin: count includes self → needs ≥ 2 to be safe.
    if Accounts.active_admin_count() <= 1, do: {:error, :last_admin}, else: :ok
  end

  defp guard_last_admin(%User{role: "admin"}) do
    # Already soft-deleted: count excludes self → needs ≥ 1 to be safe.
    if Accounts.active_admin_count() < 1, do: {:error, :last_admin}, else: :ok
  end

  defp guard_last_admin(_user), do: :ok

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

    # Step 4: COMMIT POINT — Postgres cascade, wrapped in a transaction so
    # the two writes (vault delete + user delete) either both land or both
    # roll back. Without the txn, a failure between them would leave the
    # user row with detached vault remnants — exactly the half-state the
    # cascade is meant to anchor.
    #
    # Vaults must be deleted before the user row because `notes.user_id`,
    # `attachments.user_id`, and `chunks.user_id` reference users WITHOUT
    # ON DELETE CASCADE. Deleting the user's vaults transitively cascades
    # notes/attachments/chunks (their `vault_id` FKs do cascade), clearing
    # the path for the final `Repo.delete!(user)`. Everything else hanging
    # off `users` (api_keys, subscriptions, refresh_tokens, usage_meters,
    # …) does cascade directly.
    case Repo.transaction(
           fn ->
             Repo.delete_all(
               from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id),
               skip_tenant_check: true
             )

             # `usage_buckets` is a system table (no FK to users, so the cascade
             # above does not reach it) — purge the user's rate-limit rows
             # explicitly so they don't orphan on account deletion. Raw DELETE:
             # the table has no Ecto schema and is written outside tenant scope.
             _ =
               Repo.query!("DELETE FROM usage_buckets WHERE user_id = $1::uuid", [
                 Ecto.UUID.dump!(user.id)
               ])

             Repo.delete!(user, skip_tenant_check: true)
           end,
           skip_tenant_check: true
         ) do
      {:ok, _} ->
        :telemetry.execute(
          [:engram, :account, :deleted],
          %{count: 1},
          %{user_id_hmac: HMAC.hash_user_id(user.id), reason: reason, had_sub: had_sub}
        )

        # Step 5: Clerk delete (saas only). Best-effort; Clerk row may
        # outlive ours. Future Clerk webhooks find_by_external_id →
        # :user_not_found → :ok.
        _ = delete_clerk_identity(user)

        :ok

      {:error, txn_reason} ->
        Logger.error("Hard-delete PG cascade failed — half-state recoverable on retry",
          user_id: user.id,
          reason: inspect(txn_reason)
        )

        {:error, :pg_failed}
    end
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
