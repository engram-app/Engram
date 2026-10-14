defmodule EngramWeb.Plugs.OAuthRateLimit do
  @moduledoc """
  Rate limit for the `/oauth/*` endpoints, keyed by what each endpoint is
  actually abused by (#1974).

  It used to be `EngramWeb.Plugs.RateLimit` at 10/min per path per IP. ChatGPT
  and Claude call `/oauth/token` and `/oauth/register` from shared backend
  IPs, so every one of their users drew from ONE bucket, and a busy minute
  refused everyone's refresh: the connector dies and the user re-authorizes.

    * `/oauth/token`, `/oauth/revoke`: per CLIENT (`client_id` from the body
      or HTTP Basic), #{60}/min, plus a coarse per-IP bucket (#{300}/min) so a
      caller cannot dodge the limit by inventing client ids.
    * `/oauth/register`: per IP, #{60}/min. Vendor backends register per
      connecting user; 10/min refused them.
    * `/oauth/authorize`: per IP, #{10}/min. A browser navigation; the strict
      limit stays on the unauthenticated brute-force surface.

  The client id is attacker-supplied, so it is hashed into the key (bounded
  length) and never logged.

  A 429 on `/oauth/token` carries `Retry-After` and an RFC 6749 §5.2-shaped
  body (`temporarily_unavailable`), which OAuth client libraries understand;
  the bare `rate_limited` body looked like an unknown error. A 429 is not
  logged (unbounded volume behind a bounded refusal); the `:oauth` purpose tag
  on `engram_prom_ex_rate_limiter_hit_total` is the signal (#1643).

  Overrides: test builds read `:rate_limit_override` (primary bucket) and
  `:oauth_ip_rate_limit_override` (coarse IP bucket); other builds read
  `:rate_limit_auth_override` for both (CI containers), like `RateLimit`.
  """

  alias EngramWeb.Plugs.Halt

  @period_ms 60_000
  @policy %{
    "/oauth/token" => {:client, 60},
    "/oauth/revoke" => {:client, 60},
    "/oauth/register" => {:ip, 60},
    "/oauth/authorize" => {:ip, 10}
  }
  @default_policy {:ip, 10}
  @ip_coarse_limit 300

  @is_test_build Application.compile_env(:engram, :env, :prod) == :test

  def init(opts), do: opts

  def call(conn, _opts) do
    {kind, limit} = Map.get(@policy, conn.request_path, @default_policy)
    ip = conn |> EngramWeb.RemoteIp.resolve() |> :inet.ntoa() |> to_string()

    with :ok <- coarse_ip(kind, conn.request_path, ip),
         :ok <- hit(primary_key(kind, conn, ip), primary_limit(limit)) do
      conn
    else
      {:deny, retry_after_ms} -> deny(conn, retry_after_ms)
    end
  end

  defp coarse_ip(:client, path, ip), do: hit("oauth:ip:#{path}:#{ip}", coarse_limit())
  defp coarse_ip(:ip, _path, _ip), do: :ok

  defp primary_key(:ip, conn, ip), do: "oauth:ip:#{conn.request_path}:#{ip}"

  defp primary_key(:client, conn, ip) do
    case client_id(conn) do
      nil -> "oauth:ip:#{conn.request_path}:#{ip}:anon"
      id -> "oauth:client:#{conn.request_path}:#{digest(id)}"
    end
  end

  defp client_id(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {id, _secret} when is_binary(id) and id != "" ->
        id

      _ ->
        case conn.params do
          %{"client_id" => id} when is_binary(id) and id != "" -> id
          _ -> nil
        end
    end
  end

  defp digest(id), do: :crypto.hash(:sha256, id) |> Base.url_encode64(padding: false)

  defp hit(key, limit) do
    case EngramWeb.RateLimiter.hit(key, @period_ms, limit, :oauth) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  defp deny(%Plug.Conn{request_path: "/oauth/token"} = conn, retry_after_ms) do
    seconds = retry_after_seconds(retry_after_ms)

    conn
    |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(seconds))
    |> Halt.json(429, %{
      error: "temporarily_unavailable",
      error_description: "Too many token requests for this client. Retry after #{seconds}s."
    })
  end

  defp deny(conn, retry_after_ms) do
    conn
    |> Plug.Conn.put_resp_header(
      "retry-after",
      Integer.to_string(retry_after_seconds(retry_after_ms))
    )
    |> Halt.json(429, %{error: "rate_limited"})
  end

  defp retry_after_seconds(ms) when is_integer(ms) and ms > 0, do: div(ms + 999, 1000)
  defp retry_after_seconds(_ms), do: 1

  if @is_test_build do
    defp primary_limit(default), do: Application.get_env(:engram, :rate_limit_override) || default

    defp coarse_limit,
      do: Application.get_env(:engram, :oauth_ip_rate_limit_override) || @ip_coarse_limit
  else
    defp primary_limit(default),
      do: Application.get_env(:engram, :rate_limit_auth_override) || default

    defp coarse_limit,
      do: Application.get_env(:engram, :rate_limit_auth_override) || @ip_coarse_limit
  end
end
