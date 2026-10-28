defmodule Engram.Auth.Clerk.HttpApi do
  @moduledoc """
  Live Clerk Backend API client: delete a user (revoking dup signups caught
  by pricing v2 §A normalization), check a user still exists, and read the
  latest session activity.

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

  # GET /v1/sessions?user_id= returns `latest_activity` per session with
  # `country`, `device_type` (a model string such as "iPhone", NOT a class) and
  # `is_mobile`; field names are verbatim from Clerk's OpenAPI spec. Clerk does
  # not document an order guarantee for the list, so we read a handful and take
  # the session with the greatest `last_active_at`. ip_address and city are
  # dropped here: country granularity is all the privacy policy allows.
  @impl true
  def latest_activity(clerk_user_id) when is_binary(clerk_user_id) do
    case get("/sessions", params: [user_id: clerk_user_id, limit: 10]) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_activity(body)}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only a 404 counts as "gone": a 5xx, 401 or transport error must never be
  # read as proof the identity is deleted (callers rebind accounts on false).
  @impl true
  def user_exists?(clerk_user_id) when is_binary(clerk_user_id) do
    case get("/users/#{URI.encode_www_form(clerk_user_id)}") do
      {:ok, %{status: 200}} -> {:ok, true}
      {:ok, %{status: 404}} -> {:ok, false}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get(path, opts \\ []) do
    base_url = Application.get_env(:engram, :clerk_api_base_url, @default_base_url)

    case Application.get_env(:engram, :clerk_secret_key) do
      blank when blank in [nil, ""] ->
        {:error, :missing_secret}

      secret ->
        Req.get(
          base_url <> path,
          [auth: {:bearer, secret}, receive_timeout: 10_000, retry: false] ++ opts
        )
    end
  end

  # Unpaginated, the endpoint returns a bare array; paginated, `%{"data" => [...]}`.
  defp parse_activity(%{"data" => sessions}), do: parse_activity(sessions)

  defp parse_activity(sessions) when is_list(sessions) do
    sessions
    |> Enum.filter(&match?(%{"latest_activity" => %{}}, &1))
    |> Enum.max_by(&(&1["last_active_at"] || 0), &>=/2, fn -> nil end)
    |> case do
      %{"latest_activity" => activity} ->
        %{country: country(activity["country"]), device_type: device_class(activity)}

      nil ->
        nil
    end
  end

  defp parse_activity(_other), do: nil

  # Two-letter code only. Anything else (a country name, junk) is dropped, not
  # guessed at: a wrong country is worse than a missing one.
  defp country(code) when is_binary(code) do
    code = String.upcase(code)
    if code =~ ~r/^[A-Z]{2}$/, do: code
  end

  defp country(_), do: nil

  # The class PostHog's `$device_type` uses: mobile, desktop or tablet.
  defp device_class(activity) do
    model = activity["device_type"] |> to_string() |> String.downcase()

    cond do
      model =~ ~r/ipad|tablet/ -> "tablet"
      activity["is_mobile"] == true -> "mobile"
      activity["is_mobile"] == false -> "desktop"
      true -> nil
    end
  end
end
