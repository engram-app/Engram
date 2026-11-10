defmodule EngramWeb.Plugs.OAuthRateLimit do
  @moduledoc """
  Rate limit for the `/oauth/*` endpoints, keyed by what each endpoint is
  actually abused by (#1974).

  It used to be `EngramWeb.Plugs.RateLimit` at 10/min per path per IP. ChatGPT
  and Claude call `/oauth/token` and `/oauth/register` from shared backend
  IPs, so every one of their users drew from ONE bucket, and a busy minute
  refused everyone's refresh: the connector dies and the user re-authorizes.

    * `/oauth/token`, `/oauth/revoke`: per CLIENT PER IP (`client_id` from
      the body or HTTP Basic, with the caller's IP), #{300}/min (a CIMD
      client_id is one vendor's whole user base from that IP), plus a coarse
      per-IP bucket (#{3_000}/min) so a caller cannot dodge it by inventing
      client ids. The coarse bucket is 10x the client bucket and only counts
      requests the client bucket allowed, so the client bucket trips first. Never per client alone: a CIMD `client_id` is a public URL
      shared by every user of a vendor, so a client-only bucket let anyone
      exhaust ChatGPT for everybody (review of #1974).
    * `/oauth/register`: per IP, #{60}/min. Vendor backends register per
      connecting user; 10/min refused them.
    * `/oauth/authorize`: per IP, #{300}/min. A browser navigation that checks
      no credential, so there is nothing to brute-force and the limit is only
      a flood ceiling. Everyone behind one network address shares it.

  The client id is attacker-supplied, so it is hashed into the key (bounded
  length) and never logged.

  A 429 on `/oauth/token` carries `Retry-After` and an RFC 6749 §5.2-shaped
  body (`temporarily_unavailable`), which OAuth client libraries understand;
  the bare `rate_limited` body looked like an unknown error. This plug writes
  no log of its own, but `EngramWeb.RequestLogger` ships one line per refused
  request to Loki (`GET 429`, with `route=EngramWeb.OAuthAuthorizeController#show`
  on authorize). The `:oauth` purpose tag on
  `engram_prom_ex_rate_limiter_hit_total` is what alerts (#1643).

  The buckets, ceiling and overrides are `EngramWeb.KeyedRateLimit`.
  """

  alias EngramWeb.KeyedRateLimit
  alias EngramWeb.Plugs.Halt

  @policy %{
    "/oauth/token" => {:client, 300},
    "/oauth/revoke" => {:client, 300},
    "/oauth/register" => {:ip, 60},
    "/oauth/authorize" => {:ip, 300}
  }
  @default_policy {:ip, 10}

  def init(opts), do: opts

  def call(conn, _opts) do
    config = %{
      policy: @policy,
      default: @default_policy,
      prefix: "oauth",
      purpose: :oauth,
      credential: &client_id/1
    }

    case KeyedRateLimit.check(conn, config) do
      :ok -> conn
      {:deny, path, retry_after_ms} -> deny(conn, path, retry_after_ms)
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

  defp deny(conn, "/oauth/token", retry_after_ms) do
    seconds = Halt.retry_after_seconds(retry_after_ms)

    conn
    |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(seconds))
    |> Halt.json(429, %{
      error: "temporarily_unavailable",
      error_description: "Too many token requests for this client. Retry after #{seconds}s."
    })
  end

  defp deny(conn, _path, retry_after_ms), do: Halt.rate_limited(conn, retry_after_ms)
end
