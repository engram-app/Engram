defmodule EngramWeb.Plugs.DeviceAuthRateLimit do
  @moduledoc """
  Rate limit for Obsidian plugin sign-in, on `EngramWeb.KeyedRateLimit`.

  It used to be `EngramWeb.Plugs.RateLimit` at 10/min per path per IP, so a
  room of people behind one network address drew from one bucket, and a single
  plugin polling for approval could spend it alone.

    * `/api/auth/device/token`, `/api/auth/token/refresh`: per credential,
      #{30}/min. The device code and refresh token are 256-bit secrets, so the
      limit bounds one client's retries; there is nothing to guess. Polling
      every 5s is 12/min, which leaves headroom.
    * `/api/auth/device`: per IP, #{300}/min. No credential exists yet.

  Refused with the standard `rate_limited` body and `Retry-After`. Tagged
  `purpose: :http`, not `:oauth`: the `:oauth` deny metric pages on any refusal.
  """

  alias EngramWeb.KeyedRateLimit
  alias EngramWeb.Plugs.Halt

  @policy %{
    "/api/auth/device" => {:ip, 300},
    "/api/auth/device/token" => {:secret, 30},
    "/api/auth/token/refresh" => {:secret, 30}
  }

  def init(opts), do: opts

  def call(conn, _opts) do
    config = %{
      policy: @policy,
      default: {:ip, 300},
      prefix: "device",
      purpose: :http,
      credential: &credential/1
    }

    case KeyedRateLimit.check(conn, config) do
      :ok -> conn
      {:deny, _path, retry_after_ms} -> Halt.rate_limited(conn, retry_after_ms)
    end
  end

  # Keyed on the route's own credential only: an extra parameter the route
  # ignores must not buy a fresh bucket.
  defp credential(%{path_info: ~w(api auth device token), params: %{"device_code" => code}})
       when is_binary(code) and code != "",
       do: code

  defp credential(%{path_info: ~w(api auth token refresh), params: %{"refresh_token" => token}})
       when is_binary(token) and token != "",
       do: token

  defp credential(_conn), do: nil
end
