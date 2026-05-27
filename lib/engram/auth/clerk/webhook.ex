defmodule Engram.Auth.Clerk.Webhook do
  @moduledoc """
  Routes verified Clerk webhook events. Signature verification happens upstream
  in the controller — by the time we get an event map here, it's trusted.

  Handles:
  - `user.created` — dup-check against normalized_email; revoke via Clerk API if
    duplicate, otherwise insert local user row.
  - `user.updated` — sets `users.phone_verified_at` when a verified phone
    appears (drives the §A.3 EmbedNote pre-flight gate).

  All other event types no-op.
  """

  alias Engram.Accounts
  alias Engram.Auth.EmailNormalizer
  alias Engram.Auth.SignupRejections
  alias Engram.Repo

  require Logger

  @type event :: map()

  @spec handle(event()) :: :ok
  def handle(%{"type" => "user.created", "data" => data}), do: handle_user_created(data)
  def handle(%{"type" => "user.updated", "data" => data}), do: handle_user_updated(data)
  def handle(_), do: :ok

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
        Logger.warning("Clerk signup rejected — normalized email already exists",
          clerk_user_id: clerk_id,
          normalized_email_hash: hash(normalized)
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

        Logger.error("Clerk delete_user did not revoke duplicate signup — account still live",
          clerk_user_id: clerk_id,
          reason: inspect(reason)
        )
    end
  end

  defp handle_user_updated(%{"id" => clerk_id} = data) do
    with {:ok, user} <- Accounts.find_by_external_id(clerk_id),
         true <- has_verified_phone?(data),
         nil <- user.phone_verified_at do
      user
      |> Ecto.Changeset.change(%{phone_verified_at: DateTime.utc_now()})
      |> Repo.update(skip_tenant_check: true)

      :telemetry.execute([:engram, :auth, :phone_verified], %{count: 1}, %{user_id: user.id})
      :ok
    else
      _ -> :ok
    end
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
