defmodule Engram.Auth.Clerk.HttpApi do
  @moduledoc """
  Live Clerk Backend API client. Delete-user is the only operation we need
  today (revoking dup signups caught by pricing v2 §A normalization).

  Requires `CLERK_SECRET_KEY` (sk_*) in runtime config. Tests inject
  `Engram.Auth.Clerk.ApiMock` via Mox.
  """

  @behaviour Engram.Auth.Clerk.Api

  alias Engram.Logger.Metadata

  require Logger

  @default_base_url "https://api.clerk.com/v1"

  @impl true
  def delete_user(clerk_user_id) when is_binary(clerk_user_id) do
    base_url = Application.get_env(:engram, :clerk_api_base_url, @default_base_url)
    url = "#{base_url}/users/#{URI.encode_www_form(clerk_user_id)}"

    case Application.get_env(:engram, :clerk_secret_key) do
      blank when blank in [nil, ""] ->
        # A missing secret silently disables the §A multi-account block — the
        # duplicate user can't be revoked. This is a config defect, not a no-op.
        Logger.error(
          "Clerk delete_user skipped — CLERK_SECRET_KEY not configured",
          Metadata.with_category(:error, :auth, clerk_user_id: clerk_user_id)
        )

        {:error, :missing_secret}

      secret ->
        headers = [{~c"authorization", ~c"Bearer " ++ String.to_charlist(secret)}]

        case :httpc.request(:delete, {String.to_charlist(url), headers}, [], []) do
          {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
            :ok

          # Deleting is idempotent: 404 means the Clerk user is already gone,
          # which is the outcome the caller wants. A Clerk-initiated deletion
          # (user.deleted webhook -> our hard-delete -> this call) always lands
          # here, so treating it as a failure logged an error on every one.
          {:ok, {{_, 404, _}, _, _}} ->
            Logger.info(
              "Clerk delete_user: user already gone",
              Metadata.with_category(:info, :auth, clerk_user_id: clerk_user_id)
            )

            :ok

          {:ok, {{_, status, _}, _, body}} ->
            Logger.error(
              "Clerk delete_user failed",
              Metadata.with_category(:error, :auth,
                clerk_user_id: clerk_user_id,
                status: status,
                body_size: byte_size(to_string(body))
              )
            )

            {:error, {:http_error, status}}

          {:error, reason} ->
            Logger.error(
              "Clerk delete_user transport error",
              Metadata.with_category(:error, :auth,
                clerk_user_id: clerk_user_id,
                reason: inspect(reason)
              )
            )

            {:error, reason}
        end
    end
  end

  # GET /v1/sessions?user_id= is sorted newest first; `latest_activity` holds
  # `country` (per Clerk's OpenAPI spec, the field names below are verbatim),
  # `device_type` and `is_mobile`. We read those two and drop ip_address and
  # city on the floor: country granularity is all the privacy policy allows.
  @impl true
  def latest_activity(clerk_user_id) when is_binary(clerk_user_id) do
    base_url = Application.get_env(:engram, :clerk_api_base_url, @default_base_url)

    case Application.get_env(:engram, :clerk_secret_key) do
      blank when blank in [nil, ""] ->
        {:error, :missing_secret}

      secret ->
        case Req.get("#{base_url}/sessions",
               params: [user_id: clerk_user_id, limit: 1],
               auth: {:bearer, secret},
               receive_timeout: 10_000,
               retry: false
             ) do
          {:ok, %{status: 200, body: body}} -> {:ok, parse_activity(body)}
          {:ok, %{status: status}} -> {:error, {:http_error, status}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Unpaginated, the endpoint returns a bare array; paginated, `%{"data" => [...]}`.
  defp parse_activity(%{"data" => sessions}), do: parse_activity(sessions)

  defp parse_activity([%{"latest_activity" => %{} = activity} | _]) do
    %{country: country(activity["country"]), device_type: device_type(activity)}
  end

  defp parse_activity(_none), do: nil

  # Two-letter code only. Anything else (a country name, junk) is dropped, not
  # guessed at: a wrong country is worse than a missing one.
  defp country(code) when is_binary(code) do
    code = String.upcase(code)
    if code =~ ~r/^[A-Z]{2}$/, do: code
  end

  defp country(_), do: nil

  defp device_type(%{"device_type" => type}) when is_binary(type) and type != "",
    do: String.downcase(type)

  defp device_type(%{"is_mobile" => true}), do: "mobile"
  defp device_type(%{"is_mobile" => false}), do: "desktop"
  defp device_type(_), do: nil
end
