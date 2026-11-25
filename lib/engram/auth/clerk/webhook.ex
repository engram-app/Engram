defmodule Engram.Auth.Clerk.Webhook do
  @moduledoc """
  Routes verified Clerk webhook events. Signature verification happens upstream
  in the controller — by the time we get an event map here, it's trusted.

  Handles:
  - `user.created`: creates the local row through the same path as a first
    authenticated request (`Accounts.find_or_create_by_external_id/2`). It never
    rejects or deletes the Clerk user: Clerk's "Block email subaddresses" setting
    stops Gmail dot/plus aliases at sign-up, and `users_normalized_email_index`
    is the backstop. The old webhook dup-check only ever deleted real users
    (#2292, #2293).
  - `user.updated` — mirrors the Clerk primary email into `users.email` +
    `normalized_email`, and sets `users.phone_verified_at` when a verified phone
    appears (drives the §A.3 EmbedNote pre-flight gate). Email and phone sync are
    independent.

  - `user.deleted`: runs `Lifecycle.delete_account/2`. Returns `{:error, _}`
    on a transient failure so the controller answers non-2xx and Svix retries.

  All other event types no-op.
  """

  alias Engram.Accounts
  alias Engram.Accounts.Lifecycle
  alias Engram.Auth.EmailNormalizer
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  @type event :: map()

  @spec handle(event()) :: :ok | {:error, term()}
  def handle(%{"type" => "user.created", "data" => data}), do: handle_user_created(data)
  def handle(%{"type" => "user.updated", "data" => data}), do: handle_user_updated(data)
  def handle(%{"type" => "user.deleted", "data" => data}), do: handle_user_deleted(data)
  def handle(_), do: :ok

  # Clerk fires `user.deleted` when an admin deletes a user from the Clerk
  # dashboard, when our own `Lifecycle.hard_delete` deletes the Clerk user, or
  # when a user self-deletes via the Clerk account portal. In every case the
  # upstream identity is already gone, so the local row must follow: drive the full
  # `Lifecycle.delete_account/2` cascade immediately. Step 0 of
  # `hard_delete` kicks live sockets, so the JWT cached in
  # `socket.assigns.current_user` cannot keep streaming data.
  #
  # Every failure logs `clerk_user_deleted_purge_failed` at error (the alert
  # keys on it; `reason` tells them apart). A transient failure (an
  # `{:error, _}`, a raise or an exit) returns `{:error, _}`, so the controller answers
  # 500 and leaves the svix-id unprocessed: Svix's retry finds the account
  # (already marked deleted, which `find_by_external_id/1` does not filter) and
  # `delete_account/2`, idempotent, finishes it.
  #
  # The last-admin guard is NOT transient: nothing changes between retries
  # unless ops promotes another admin and re-runs the purge by hand. Svix
  # retries one message 8 times over about 27 hours, so a non-2xx would only
  # help if ops acted inside that window, and the error line is what tells ops
  # to act either way. It acks, logs, and leaves the user soft-deleted.
  defp handle_user_deleted(%{"id" => clerk_id}) when is_binary(clerk_id) do
    case Accounts.find_by_external_id(clerk_id) do
      {:ok, user} -> purge_deleted_user(user)
      {:error, :user_not_found} -> :ok
    end
  end

  defp handle_user_deleted(_), do: :ok

  defp purge_deleted_user(user) do
    case Lifecycle.delete_account(user, :clerk) do
      :ok ->
        :ok

      {:error, :last_admin} ->
        :telemetry.execute(
          [:engram, :auth, :clerk_user_deleted_last_admin_protected],
          %{count: 1},
          %{user_id: user.id}
        )

        log_purge_failed(user, Metadata.safe_reason(:last_admin))
        :ok

      {:error, reason} = err ->
        log_purge_failed(user, Metadata.safe_reason(reason))
        err
    end
  rescue
    e ->
      stacktrace = __STACKTRACE__
      _ = Sentry.capture_exception(e, stacktrace: stacktrace)

      log_purge_failed(
        user,
        "#{Metadata.safe_reason(e)} at=#{Metadata.format_location(stacktrace)}"
      )

      {:error, :exception}
  catch
    :exit, reason ->
      safe = "exit " <> Metadata.safe_reason(reason)
      _ = Sentry.capture_message("clerk_user_deleted_purge_failed", extra: %{reason: safe})
      log_purge_failed(user, safe)
      {:error, :exit}
  end

  defp log_purge_failed(user, reason) do
    Logger.error(
      "clerk_user_deleted_purge_failed",
      Metadata.with_category(:error, :lifecycle, user_id: user.id, reason: reason)
    )
  end

  # Same path as JIT, so the webhook and a racing first request converge on
  # one row; the unique indexes decide atomically. No verified primary email:
  # skip, the user's first request still creates the row. A conflict (the email or an
  # alias of it belongs to another account) leaves the Clerk user alone: the
  # auth plug answers that identity 403 `account_conflict`, and the find/create
  # call already logs it.
  defp handle_user_created(%{"id" => clerk_id} = data) do
    with {:ok, email} <- primary_email(data) do
      _ = Accounts.find_or_create_by_external_id(clerk_id, %{email: email})
    end

    :ok
  end

  defp handle_user_updated(%{"id" => clerk_id} = data) do
    case Accounts.find_by_external_id(clerk_id) do
      {:ok, user} ->
        # Email and phone sync are independent — a no-op on one must not skip the
        # other. They touch disjoint columns, so order doesn't matter.
        sync_primary_email(user, data)
        sync_verified_phone(user, data)
        :ok

      {:error, :user_not_found} ->
        :ok
    end
  end

  # Mirror the Clerk primary email into users.email + normalized_email. Idempotent
  # (user.updated fires on any profile change). On a normalized-email collision
  # with another account, keep the stored values — losing the §A anti-farming key
  # is worse than cosmetic drift — and emit abuse telemetry instead of raising
  # (a raise → 500 → Clerk retries forever).
  defp sync_primary_email(user, data) do
    with {:ok, email} <- primary_email(data),
         normalized = EmailNormalizer.normalize(email),
         true <- email != user.email or normalized != user.normalized_email do
      user
      |> Ecto.Changeset.change(%{email: email, normalized_email: normalized})
      |> Ecto.Changeset.unique_constraint(:email, name: :users_email_lower_index)
      |> Ecto.Changeset.unique_constraint(:normalized_email,
        name: :users_normalized_email_index
      )
      |> Repo.update(skip_tenant_check: true)
      |> case do
        {:ok, _user} ->
          # The PostHog person is keyed on the email, so a new email starts a
          # new person. Erase the old one now: account erasure only ever finds
          # the current email's person, and the old one holds email and name.
          # Trade-off: the user's pre-change analytics history goes with it.
          :ok = Engram.Analytics.forget_previous_email(user.email, email)
          :ok

        {:error, _changeset} ->
          :telemetry.execute(
            [:engram, :abuse, :email_sync_collision],
            %{count: 1},
            %{user_id: user.id, normalized_email_hash: hash(normalized)}
          )

          Logger.warning(
            "Clerk email sync skipped — normalized email collides with another user",
            Metadata.with_category(:warning, :lifecycle,
              user_id: user.id,
              normalized_email_hash: hash(normalized)
            )
          )

          :ok
      end
    else
      _ -> :ok
    end
  end

  defp sync_verified_phone(user, data) do
    if has_verified_phone?(data) and is_nil(user.phone_verified_at) do
      user
      |> Ecto.Changeset.change(%{phone_verified_at: DateTime.utc_now()})
      |> Repo.update(skip_tenant_check: true)

      :telemetry.execute([:engram, :auth, :phone_verified], %{count: 1}, %{user_id: user.id})
    end

    :ok
  end

  # Only the VERIFIED primary address counts, with no fallback to the first
  # address. It can link a row with no external_id (legacy / pre-Clerk) and
  # replace a user's email, and a Clerk user made through the Backend API or
  # some OAuth providers can carry an email nobody proved they own.
  defp primary_email(%{"primary_email_address_id" => pid, "email_addresses" => addrs})
       when is_binary(pid) and is_list(addrs) do
    case Enum.find(addrs, &(&1["id"] == pid)) do
      %{"email_address" => email, "verification" => %{"status" => "verified"}}
      when is_binary(email) ->
        {:ok, email}

      _ ->
        {:error, :no_verified_primary_email}
    end
  end

  defp primary_email(_), do: {:error, :no_verified_primary_email}

  defp has_verified_phone?(%{"phone_numbers" => phones}) when is_list(phones) do
    Enum.any?(phones, fn p -> get_in(p, ["verification", "status"]) == "verified" end)
  end

  defp has_verified_phone?(_), do: false

  defp hash(str),
    do: :crypto.hash(:sha256, str) |> Base.encode16(case: :lower) |> binary_part(0, 12)
end
