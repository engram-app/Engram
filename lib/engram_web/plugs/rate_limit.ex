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

  A 429 here is deliberately NOT logged, unlike every other refusal on that
  path (#1643). `/oauth/*` is unauthenticated, so one line per over-limit
  attempt is unbounded log volume behind a bounded refusal — the same trade
  `Engram.OAuth.Cimd` already makes for `:rate_limited`. The metric carries the
  volume; logs stay for anomalies.
  """

  alias EngramWeb.Plugs.Halt

  # Bake the build env into the module at compile time.
  # This ensures :rate_limit_override is structurally impossible in non-test builds.
  @build_env Application.compile_env(:engram, :env, :prod)
  @is_test_build @build_env == :test

  def init(opts) do
    %{
      limit: Keyword.fetch!(opts, :limit),
      period: Keyword.fetch!(opts, :period),
      purpose: Keyword.get(opts, :purpose, :http)
    }
  end

  def call(conn, %{limit: limit, period: period, purpose: purpose}) do
    effective_limit = effective_limit(limit)

    key = rate_limit_key(conn)

    case EngramWeb.RateLimiter.hit(key, period, effective_limit, purpose) do
      {:allow, _count} ->
        conn

      {:deny, _retry_after_ms} ->
        Halt.json(conn, 429, %{error: "rate_limited"})
    end
  end

  # Compile-time branch: test builds check :rate_limit_override (config/test.exs).
  # Non-test builds check :rate_limit_auth_override (runtime.exs, set via env var
  # in CI Docker containers). Fly.io prod deploys don't set this env var.
  if @is_test_build do
    defp effective_limit(default) do
      Application.get_env(:engram, :rate_limit_override) || default
    end
  else
    defp effective_limit(default) do
      Application.get_env(:engram, :rate_limit_auth_override) || default
    end
  end

  defp rate_limit_key(conn) do
    # EngramWeb.RemoteIp resolves the real client IP: the trusted
    # CF-Connecting-IP in prod (behind Cloudflare AOP), else the raw socket IP.
    # Never trusts x-forwarded-for directly — that is client-spoofable.
    ip = conn |> EngramWeb.RemoteIp.resolve() |> :inet.ntoa() |> to_string()
    "#{conn.request_path}:#{ip}"
  end
end
