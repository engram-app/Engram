defmodule Engram.Accounts.Lifecycle do
  @moduledoc """
  Soft + hard account-delete pipeline shared by user-initiated delete,
  Clerk `user.deleted` webhook, and the inactivity sweep.

  Soft = reversible (sets `deleted_at`, queues the Qdrant drop, revokes tokens,
  emails). Hard = cascade purge of every store (sessions, Paddle, S3, PG, Clerk,
  PostHog), then queues the Qdrant drop.

  Qdrant is never called inline: both entry points run inside the DELETE
  /api/me request (and the Clerk webhook), so the drop is an Oban job,
  `Engram.Workers.DropUserVectors`, inserted only after the delete it serves
  has taken effect.

  Both are idempotent.
  """

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Analytics
  alias Engram.Auth.SessionInvalidator
  alias Engram.Billing.Subscription
  alias Engram.Crypto.HMAC
  alias Engram.Indexing
  alias Engram.Logger.Metadata
  alias Engram.Mailer
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Workers.DropUserVectors
  alias Engram.Workers.PaddleCancelSubscription

  require Logger

  @type reason :: :user | :clerk | :inactivity

  @doc """
  Soft-deletes a user: stamps `users.deleted_at`, queues the Qdrant drop,
  revokes refresh tokens, and emails the account-deleted notice.

  No-op on a user that already carries `deleted_at` — idempotent.

  The user's vector data is unreachable once `deleted_at` is set; the queued
  drop retries until Qdrant takes it.
  """
  @spec soft_delete(User.t(), reason()) :: :ok
  def soft_delete(%User{deleted_at: %DateTime{}} = user, _reason) do
    # Idempotent retry path: tokens may have been re-issued between attempts
    # (e.g. delete_self crashed after soft_delete, user retried). Revoke
    # again — `revoke_all_user_tokens` is idempotent. Skip the Qdrant drop
    # enqueue, email, and telemetry; those already fired on the first call.
    Accounts.revoke_all_user_tokens(user)
    :ok
  end

  def soft_delete(%User{} = user, reason) do
    user
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
    |> Repo.update!(skip_tenant_check: true)

    # The points outlive this call until the job runs, and the chunk rows
    # survive it (the hard-delete sweep collects them). A row whose point is
    # gone but whose `context_hmac` is intact makes a later re-index "reuse" an
    # id that no longer exists in Qdrant, so the markers go now, before the
    # drop. See `Indexing.forget_chunk_reuse_for_user/1`.
    :ok = Indexing.forget_chunk_reuse_for_user(user.id)
    _ = enqueue_qdrant_drop(user.id)

    Accounts.evict_user(user.id)
    Accounts.revoke_all_user_tokens(user)
    _ = Mailer.send_account_deleted_notice(user, reason)

    :telemetry.execute(
      [:engram, :account, :soft_deleted],
      %{count: 1},
      %{user_id_hmac: HMAC.hash_user_id(user.id), reason: reason}
    )

    Logger.info(
      "account soft-deleted",
      Metadata.with_category(:info, :lifecycle, user_id: user.id, reason: reason)
    )

    :ok
  end

  @doc """
  Hard-deletes a user: cascade-purges every store the account touches.

  Ordering (spec §7.2) is best-effort, not transactional — it spans S3 +
  Postgres + Paddle + Clerk (+ the queued Qdrant drop), none of which share a
  commit boundary.
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
    # Scoped (#1758): an unscoped read under an enforced `subscriptions` policy
    # finds nothing, skips the Paddle cancel, and the deleted user keeps being
    # billed.
    sub =
      Repo.with_tenant!(user.id, fn ->
        Repo.one(from(s in Subscription, where: s.user_id == ^user.id))
      end)

    had_sub = not is_nil(sub && sub.paddle_subscription_id)

    # Step 0: Kick live sockets before any data wipe. Otherwise the JWT
    # cached in socket assigns keeps streaming until the connection drops.
    _ = SessionInvalidator.disconnect_user(user.id)

    # Step 1: Paddle cancel (best-effort). A failure here does NOT enqueue
    # the async retry yet — see the `{:ok, _}` transaction branch below.
    # Enqueueing here would let the retry job outlive a rolled-back Step 4:
    # `{:error, :pg_failed}` means the user is still live, and a queued
    # retry would later cancel a paying, non-deleted user's subscription.
    paddle_retry = cancel_paddle_subscription(user, sub)

    # Step 2 (Qdrant vectors) is queued in the `{:ok, _}` branch below, for
    # the Paddle-retry reason: a drop queued before Step 4 would outlive a
    # rolled-back delete.

    # Step 3: S3 prefixes — user blobs + exports. Retry once on failure.
    _ = wipe_storage_prefix(user, "#{user.id}/")
    _ = wipe_storage_prefix(user, "exports/#{user.id}/")

    # Read before Step 4 deletes the row: the answer a delete_account feedback
    # submit stashed there is sent only once the delete commits.
    profile =
      Repo.one(from(u in User, where: u.id == ^user.id, select: u.onboarding_profile),
        skip_tenant_check: true
      )

    # Same reason: erasure takes the user's PostHog history with it, so who
    # left is read now and sent, person-less, once the delete commits.
    summary = deletion_summary(user, sub, reason)

    # Step 4: COMMIT POINT — Postgres cascade, wrapped in a transaction so
    # the two writes (vault delete + user delete) either both land or both
    # roll back. Without the txn, a failure between them would leave the
    # user row with detached vault remnants — exactly the half-state the
    # cascade is meant to anchor.
    #
    # Vaults must be deleted before the user row because `notes.user_id`,
    # `attachments.user_id`, and `chunks.user_id` reference users WITHOUT
    # ON DELETE CASCADE (verified: `confdeltype = 'a'`). Deleting the user's
    # vaults transitively cascades notes/attachments/chunks (their `vault_id`
    # FKs are `'c'`), clearing the path for the final `Repo.delete!(user)`.
    # Everything else hanging off `users` (api_keys, subscriptions,
    # refresh_tokens, usage_meters, …) does cascade directly.
    #
    # `with_tenant/2`, NOT a bare `Repo.transaction`: `vaults` carries FORCE
    # ROW LEVEL SECURITY, so under a role the policy applies to, an unscoped
    # `delete_all` is FILTERED to zero rows and reports `{0, nil}` WITHOUT
    # raising. Nothing then cascades, and the `Repo.delete!(user)` below dies
    # on `notes_user_id_fkey` — account deletion could not complete at all,
    # and the operator saw a Postgres FK error about `notes` rather than
    # anything naming tenant scoping. `skip_tenant_check: true` did not and
    # could not help: it suppresses Engram's application-level tripwire and
    # sets no Postgres state whatsoever.
    case Repo.with_tenant(
           user.id,
           fn ->
             Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id))

             # No `usage_buckets` purge any more: the AI search budget moved out
             # of Postgres into the cluster-synced ETS counter
             # (`EngramWeb.RateLimiter`), and the table is dropped. An ETS
             # bucket keyed on a deleted user id ages out with its window and
             # orphans nothing.
             Repo.delete!(user, skip_tenant_check: true)
           end
         ) do
      {:ok, _} ->
        Accounts.evict_user(user.id)

        :telemetry.execute(
          [:engram, :account, :deleted],
          %{count: 1},
          %{user_id_hmac: HMAC.hash_user_id(user.id), reason: reason, had_sub: had_sub}
        )

        Logger.info(
          "account hard-deleted",
          Metadata.with_category(:info, :lifecycle, user_id: user.id, reason: reason)
        )

        # The commit landed, so the account really is gone — safe to enqueue
        # the Paddle retry now (see the Step 1 comment above).
        _ = maybe_enqueue_paddle_retry(user.id, paddle_retry)

        # Same rule. After a soft_delete in the same call this dedupes into
        # the job soft_delete queued; after an inactivity soft delete weeks
        # ago it is a fresh, idempotent safety-net drop.
        _ = enqueue_qdrant_drop(user.id)

        # Step 5: Clerk delete (saas only). Best-effort; Clerk row may
        # outlive ours. Future Clerk webhooks find_by_external_id →
        # :user_not_found → :ok.
        _ = delete_clerk_identity(user)

        _ = Engram.Feedback.capture_delete_reason(profile)

        _ =
          unless Analytics.opted_out?(user),
            do: Analytics.track_anonymous("account_deleted", summary)

        # Analytics erasure, only once the delete has committed: queued before
        # Step 4, a rolled-back delete would still wipe a live user's analytics
        # (the Step 1 Paddle-retry rule). Covers the analytics-id person and the
        # legacy Clerk-id one, now and again 10 minutes later; the jobs retry.
        :ok = Analytics.forget(user)

        :ok

      {:error, txn_reason} ->
        Logger.error(
          "Hard-delete PG cascade failed — half-state recoverable on retry",
          Metadata.with_category(:error, :lifecycle,
            user_id: user.id,
            reason: inspect(txn_reason)
          )
        )

        {:error, :pg_failed}
    end
  end

  # Returns `:ok` (nothing to cancel, or Paddle confirmed it) or
  # `{:retry, sub_id}` — the caller enqueues the async retry only once the
  # hard-delete transaction actually commits.
  # Coarse buckets only: an anonymous event must not single anyone out.
  defp deletion_summary(user, sub, reason) do
    tenure_days = DateTime.diff(DateTime.utc_now(), user.created_at, :day)

    # Scoped: both are tenant tables, so an unscoped read under enforced RLS
    # finds nothing and every summary would report no surfaces.
    {connected, api?} =
      Repo.with_tenant!(user.id, fn ->
        {Repo.all(
           from(a in Engram.Onboarding.Action,
             where: a.user_id == ^user.id and a.action in ["plugin_connected", "ai_connected"],
             select: a.action
           )
         ), Repo.exists?(from(k in Engram.Accounts.ApiKey, where: k.user_id == ^user.id))}
      end)

    used =
      [
        {"obsidian", "plugin_connected" in connected},
        {"mcp", "ai_connected" in connected},
        {"api", api?}
      ]
      |> Enum.flat_map(fn {name, used?} -> if used?, do: [name], else: [] end)
      |> Enum.sort()

    %{
      tenure_bucket:
        bucket(tenure_days, [{1, "0_1"}, {7, "1_7"}, {30, "7_30"}, {90, "30_90"}], "90_plus"),
      plan: Engram.Analytics.PersonProperties.plan(sub && sub.tier, sub && sub.status),
      notes_bucket:
        bucket(
          Engram.UsageMeters.notes_count(user.id),
          [{1, "0"}, {10, "1_10"}, {100, "10_100"}, {1000, "100_1000"}],
          "1000_plus"
        ),
      surfaces_used: used,
      trigger: Atom.to_string(reason)
    }
  end

  defp bucket(n, bounds, top) do
    Enum.find_value(bounds, top, fn {below, label} -> if n < below, do: label end)
  end

  defp cancel_paddle_subscription(_user, nil), do: :ok
  defp cancel_paddle_subscription(_user, %Subscription{paddle_subscription_id: nil}), do: :ok

  defp cancel_paddle_subscription(user, %Subscription{paddle_subscription_id: sub_id}) do
    case PaddleCancelSubscription.cancel(user.id, sub_id) do
      {:ok, _data} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Paddle cancel failed during hard-delete",
          Metadata.with_category(:error, :lifecycle,
            user_id: user.id,
            paddle_subscription_id: sub_id,
            reason: inspect(reason)
          )
        )

        {:retry, sub_id}
    end
  rescue
    e ->
      Logger.error(
        "Paddle cancel raised during hard-delete",
        Metadata.with_category(:error, :lifecycle,
          user_id: user.id,
          exception: inspect(e)
        )
      )

      {:retry, sub_id}
  end

  defp maybe_enqueue_paddle_retry(_user_id, :ok), do: :ok

  defp maybe_enqueue_paddle_retry(user_id, {:retry, sub_id}),
    do: PaddleCancelSubscription.enqueue(user_id, sub_id)

  # Single retry on first failure. Second failure: log + continue. S3
  # lifecycle rules sweep stragglers at the per-prefix 30-day mark.
  defp wipe_storage_prefix(user, prefix) do
    case Storage.adapter().delete_prefix(prefix) do
      {:ok, _count} ->
        :ok

      {:error, first_reason} ->
        case Storage.adapter().delete_prefix(prefix) do
          {:ok, _count} ->
            Logger.warning(
              "Storage prefix delete succeeded on retry during hard-delete",
              Metadata.with_category(:warning, :lifecycle,
                user_id: user.id,
                prefix: prefix,
                first_reason: inspect(first_reason)
              )
            )

            :ok

          {:error, retry_reason} ->
            Logger.error(
              "Storage prefix delete failed twice during hard-delete",
              Metadata.with_category(:error, :lifecycle,
                user_id: user.id,
                prefix: prefix,
                first_reason: inspect(first_reason),
                retry_reason: inspect(retry_reason)
              )
            )

            :error
        end
    end
  rescue
    e ->
      Logger.error(
        "Storage prefix delete raised during hard-delete",
        Metadata.with_category(:error, :lifecycle,
          user_id: user.id,
          prefix: prefix,
          exception: inspect(e)
        )
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
        Logger.error(
          "Clerk delete_user failed during hard-delete",
          Metadata.with_category(:error, :lifecycle,
            user_id: user.id,
            clerk_user_id: external_id,
            reason: inspect(reason)
          )
        )

        :error
    end
  rescue
    e ->
      Logger.error(
        "Clerk delete_user raised during hard-delete",
        Metadata.with_category(:error, :lifecycle,
          user_id: user.id,
          clerk_user_id: external_id,
          exception: inspect(e)
        )
      )

      :error
  end

  defp clerk_api do
    Application.get_env(:engram, :clerk_api, Engram.Auth.Clerk.HttpApi)
  end

  # Best-effort like every other post-commit step: an insert failure is logged
  # and OrphanSweep collects the points once the user row is gone.
  defp enqueue_qdrant_drop(user_id) do
    case DropUserVectors.enqueue(user_id) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Qdrant drop enqueue failed during account delete",
          Metadata.with_category(:error, :lifecycle,
            user_id: user_id,
            reason: Metadata.safe_reason(reason)
          )
        )

        :error
    end
  end
end
