defmodule EngramWeb.Plugs.RateLimit do
  @moduledoc """
  Configurable rate-limiting plug backed by `EngramWeb.RateLimiter`.
  Usage: `plug EngramWeb.Plugs.RateLimit, limit: 10, period: 60_000`

  ## `:purpose`

  Tags this mount's limiter telemetry (`Engram.PromEx.RateLimiter`), defaulting
  to `:http`. The OAuth pipeline passes `:oauth` so a refused connector is
  attributable: a 429 there means a vendor cannot reach the token or authorize
  endpoint at all, which is indistinguishable from unrelated traffic under one
  shared tag.

  This plug writes no log of its own for a 429 (#1643); `EngramWeb.RequestLogger`
  ships the one request line, and the metric carries the volume.
  """

  alias EngramWeb.KeyedRateLimit
  alias EngramWeb.Plugs.Halt

  def init(opts) do
    %{
      limit: Keyword.fetch!(opts, :limit),
      period: Keyword.fetch!(opts, :period),
      purpose: Keyword.get(opts, :purpose, :http)
    }
  end

  def call(conn, %{limit: limit, period: period, purpose: purpose}) do
    effective_limit = KeyedRateLimit.effective_limit(limit)

    key = rate_limit_key(conn)

    case EngramWeb.RateLimiter.hit(key, period, effective_limit, purpose) do
      {:allow, _count} ->
        conn

      {:deny, _retry_after_ms} ->
        Halt.json(conn, 429, %{error: "rate_limited"})
    end
  end

  defp rate_limit_key(conn) do
    "#{conn.request_path}:#{KeyedRateLimit.client_ip(conn)}"
  end
end
