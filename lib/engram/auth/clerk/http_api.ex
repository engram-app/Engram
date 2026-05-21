defmodule Engram.Auth.Clerk.HttpApi do
  @moduledoc """
  Live Clerk Backend API client. Delete-user is the only operation we need
  today (revoking dup signups caught by pricing v2 §A normalization).

  Requires `CLERK_SECRET_KEY` (sk_*) in runtime config. Tests inject
  `Engram.Auth.Clerk.ApiMock` via Mox.
  """

  @behaviour Engram.Auth.Clerk.Api

  require Logger

  @base_url "https://api.clerk.com/v1"

  @impl true
  def delete_user(clerk_user_id) when is_binary(clerk_user_id) do
    url = "#{@base_url}/users/#{URI.encode_www_form(clerk_user_id)}"

    case Application.get_env(:engram, :clerk_secret_key) do
      nil ->
        {:error, :missing_secret}

      "" ->
        {:error, :missing_secret}

      secret ->
        headers = [{~c"authorization", ~c"Bearer " ++ String.to_charlist(secret)}]

        case :httpc.request(:delete, {String.to_charlist(url), headers}, [], []) do
          {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
            :ok

          {:ok, {{_, status, _}, _, body}} ->
            Logger.error("Clerk delete_user failed",
              clerk_user_id: clerk_user_id,
              status: status,
              body_size: byte_size(to_string(body))
            )

            {:error, {:http_error, status}}

          {:error, reason} ->
            Logger.error("Clerk delete_user transport error",
              clerk_user_id: clerk_user_id,
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end
end
