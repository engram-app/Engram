defmodule EngramWeb.Plugs.UserCodeRateLimit do
  @moduledoc """
  Per-user budget for testing a device user code (RFC 8628 section 5.1).

  A user code is short enough to type, about 39 bits, so unlike the device code
  it can be guessed. A signed-in user can try one by approving it
  (`POST /api/auth/device/authorize`) or by asking whether it is valid
  (`GET /api/vaults?user_code=`). Both mount this plug and spend one budget, or
  the cheaper route would stay a free oracle. A request without a user code
  spends nothing.

  The limit is `config :engram, :user_code_rate_limit`.
  """

  alias EngramWeb.KeyedRateLimit
  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(
        %{params: %{"user_code" => code}, assigns: %{current_user: user}} = conn,
        _opts
      )
      when is_binary(code) and code != "" do
    opts = Application.fetch_env!(:engram, :user_code_rate_limit)
    limit = KeyedRateLimit.effective_limit(Keyword.fetch!(opts, :limit))
    period_ms = Keyword.fetch!(opts, :period_ms)

    case EngramWeb.RateLimiter.hit("user_code:#{user.id}", period_ms, limit, :device_user_code) do
      {:allow, _count} -> conn
      {:deny, retry_after_ms} -> Halt.rate_limited(conn, retry_after_ms)
    end
  end

  def call(conn, _opts), do: conn
end
