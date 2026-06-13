defmodule EngramWeb.Plugs.RateLimit do
  @moduledoc """
  Configurable rate-limiting plug backed by `EngramWeb.RateLimiter`.
  Usage: `plug EngramWeb.Plugs.RateLimit, limit: 10, period: 60_000`
  """

  import Plug.Conn

  # Bake the build env into the module at compile time.
  # This ensures :rate_limit_override is structurally impossible in non-test builds.
  @build_env Application.compile_env(:engram, :env, :prod)
  @is_test_build @build_env == :test

  def init(opts) do
    %{
      limit: Keyword.fetch!(opts, :limit),
      period: Keyword.fetch!(opts, :period)
    }
  end

  def call(conn, %{limit: limit, period: period}) do
    effective_limit = effective_limit(limit)

    key = rate_limit_key(conn)

    case EngramWeb.RateLimiter.hit(key, period, effective_limit) do
      {:allow, _count} ->
        conn

      {:deny, _retry_after_ms} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
        |> halt()
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
