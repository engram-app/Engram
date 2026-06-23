defmodule Engram.Auth.Clerk.Webhook do
  @moduledoc """
  Routes verified Clerk webhook events. Signature verification happens upstream
  in the controller — by the time we get an event map here, it's trusted.

  Handles:
  - `user.created` — dup-check against normalized_email; revoke via Clerk API if
    duplicate, otherwise insert local user row.
  - `user.updated` — mirrors the Clerk primary email into `users.email` +
    `normalized_email`, and sets `users.phone_verified_at` when a verified phone
    appears (drives the §A.3 EmbedNote pre-flight gate). Email and phone sync are
    independent.

  All other event types no-op.
  """

  alias Engram.Accounts
  alias Engram.Auth.EmailNormalizer
  alias Engram.Auth.SignupRejections
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  @type event :: map()

  @spec handle(event()) :: :ok
  def handle(%{"type" => "user.created", "data" => data}), do: handle_user_created(data)
  def handle(%{"type" => "user.updated", "data" => data}), do: handle_user_updated(data)
  def handle(%{"type" => "user.deleted", "data" => data}), do: handle_user_deleted(data)
  def handle(_), do: :ok

  # Clerk fires `user.deleted` when an admin deletes a user from the Clerk
  # dashboard, when Clerk itself revokes a user (e.g. the duplicate-signup
  # branch in `apply_user_created/3`), or when a user self-deletes via the
  # Clerk account portal. In every case the upstream identity is already
  # gone, so the local row must follow — drive the full
  # `soft_delete` + `hard_delete` cascade immediately. Step 0 of
  # `hard_delete` kicks live sockets, so the JWT cached in
  # `socket.assigns.current_user` cannot keep streaming data.
  #
  # Clerk is authoritative on identity, but `Lifecycle.hard_delete` carries
  # a last-admin guard (so user-flow, inactivity sweeps, and this webhook
  # can never strand the instance admin-less). If the deleted user IS the
  # last admin, we can't reject the webhook — Clerk has already torn down
  # the upstream identity, and a non-2xx response would just be retried
  # forever. Log + emit telemetry + leave them soft-deleted; ops promotes
  # another admin and re-runs the purge manually.
  defp handle_user_deleted(%{"id" => clerk_id}) when is_binary(clerk_id) do
    case Accounts.find_by_external_id(clerk_id) do
      {:ok, user} ->
        :ok = Engram.Accounts.Lifecycle.soft_delete(user, :clerk)

        case Engram.Accounts.Lifecycle.hard_delete(user, :clerk) do
          :ok ->
            :ok

          {:error, :last_admin} ->
            :telemetry.execute(
              [:engram, :auth, :clerk_user_deleted_last_admin_protected],
              %{count: 1},
              %{user_id: user.id}
            )

            Logger.warning(
              "Clerk user.deleted blocked by last-admin guard; user stays soft-deleted",
              Metadata.with_category(:warning, :lifecycle,
                user_id: user.id,
                clerk_user_id: clerk_id
              )
            )

            :ok

          {:error, _other} ->
            # PG cascade failed; soft_delete already fired, retry will be
            # driven by the next inactivity sweep or an operator.
            :ok
        end

      {:error, :user_not_found} ->
        :ok
    end
  end

  defp handle_user_deleted(_), do: :ok

  defp handle_user_created(%{"id" => clerk_id} = data) do
    case Accounts.find_by_external_id(clerk_id) do
      {:ok, _user} ->
        :ok

      {:error, :user_not_found} ->
        case primary_email(data) do
          {:error, _} ->
            :ok

          {:ok, email} ->
            normalized = EmailNormalizer.normalize(email)
            apply_user_created(clerk_id, email, normalized)
        end
    end
  end

  defp apply_user_created(clerk_id, email, normalized) do
    case Accounts.find_by_normalized_email(normalized) do
      {:ok, _existing} ->
        Logger.warning(
          "Clerk signup rejected — normalized email already exists",
          Metadata.with_category(:warning, :auth,
            clerk_user_id: clerk_id,
            normalized_email_hash: hash(normalized)
          )
        )

        # Stash the reason before the delete orphans the session, so the web app
        # can fetch it and explain the bounce instead of failing silently.
        SignupRejections.record(clerk_id, :duplicate_identity)
        revoke_duplicate(clerk_id, normalized)
        :ok

      {:error, :user_not_found} ->
        _ = Accounts.find_or_create_by_external_id(clerk_id, %{email: email})
        :ok
    end
  end

  # The block is only real if Clerk actually revokes the duplicate. A failed
  # delete (e.g. missing CLERK_SECRET_KEY) leaves the duplicate account live and
  # signed in — count the outcome, not the intent, and make a failure alertable.
  defp revoke_duplicate(clerk_id, normalized) do
    case clerk_api().delete_user(clerk_id) do
      :ok ->
        :telemetry.execute(
          [:engram, :abuse, :multi_account_blocked],
          %{count: 1},
          %{normalized_email_hash: hash(normalized)}
        )

      {:error, reason} ->
        :telemetry.execute(
          [:engram, :abuse, :multi_account_block_failed],
          %{count: 1},
          %{normalized_email_hash: hash(normalized), reason: inspect(reason)}
        )

        Logger.error(
          "Clerk delete_user did not revoke duplicate signup — account still live",
          Metadata.with_category(:error, :auth,
            clerk_user_id: clerk_id,
            reason: inspect(reason)
          )
        )
    end
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

  defp primary_email(%{"primary_email_address_id" => pid, "email_addresses" => addrs})
       when is_list(addrs) do
    case Enum.find(addrs, &(&1["id"] == pid)) do
      %{"email_address" => email} when is_binary(email) -> {:ok, email}
      _ -> {:error, :no_primary_email}
    end
  end

  defp primary_email(%{"email_addresses" => [%{"email_address" => email} | _]})
       when is_binary(email),
       do: {:ok, email}

  defp primary_email(_), do: {:error, :no_primary_email}

  defp has_verified_phone?(%{"phone_numbers" => phones}) when is_list(phones) do
    Enum.any?(phones, fn p -> get_in(p, ["verification", "status"]) == "verified" end)
  end

  defp has_verified_phone?(_), do: false

  defp hash(str),
    do: :crypto.hash(:sha256, str) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp clerk_api do
    Application.get_env(:engram, :clerk_api, Engram.Auth.Clerk.HttpApi)
  end
end
