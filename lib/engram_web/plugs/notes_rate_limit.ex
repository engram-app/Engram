defmodule EngramWeb.Plugs.NotesRateLimit do
  @moduledoc """
  Application-layer rate limiter defending `/api/notes/*` against 401-loop
  attacks. Defense-in-depth for the Cloudflare ruleset that was dropped in
  engram-infra#361 — the Free CF tier cannot count response-conditional
  (auth-rejected) requests, so this plug picks up the slack.

  ## Placement

  This plug MUST run **before** `EngramWeb.Plugs.Auth`. The whole point is
  that requests rejected by auth (bad JWT, expired, etc.) still consume
  bucket capacity — otherwise an attacker can hammer the API forever with
  any garbage Bearer token. See the vault-scoped pipeline in
  `EngramWeb.Router`.

  ## Bucket key

  `notes:<ip>:<sub-or-anon>`

  * `ip` — `conn.remote_ip` (the TCP peer, or a trusted-proxy-resolved IP
    via `Plug.RewriteOn`; never `x-forwarded-for` directly — that's
    client-controlled, see `EngramWeb.Plugs.RateLimit`).
  * `sub` — the unverified `sub` claim from the Bearer JWT, OR `anon` if
    there is no JWT or the token is malformed. We do **not** verify the
    signature here; the claim is used purely as a bucket key — no
    authority is granted on its basis. This keeps a legitimate user's
    bucket distinct from anonymous traffic sharing the same NAT/egress IP,
    while still letting the IP fallback catch a stream of garbage tokens
    from a single attacker host.

  API keys (Bearer engram_*) get their own bucket keyed by the prefix so
  one rotated key cannot starve a sibling key on the same host.

  ## Limits

  Defaults: 600 req per 60s sliding window per `{ip, sub}` bucket. Override
  via `Application.get_env(:engram, :notes_rate_limit_override, integer)`
  for CI / load tests / regional adjustments. Tuned well above the
  authenticated `RequireApiRpsBudget` per-plan caps (Pro = 30 rps = 1800
  rpm); this is a coarse net for the unauthenticated 401-loop case, not
  per-plan policy.

  ## Response on overage

  HTTP 429 + JSON body `{"error":"rate_limited"}` plus headers:
  * `Retry-After: <seconds>` — RFC 7231 §7.1.3, in seconds
  * `X-RateLimit-Limit: <n>` — bucket capacity
  * `X-RateLimit-Remaining: 0` — explicit so clients can short-circuit

  Allowed responses also carry `X-RateLimit-Limit` and
  `X-RateLimit-Remaining` so well-behaved clients can self-throttle before
  the cliff.
  """

  import Plug.Conn

  @path_prefix "/api/notes"

  @default_limit 600
  @default_period_ms 60_000

  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, @default_limit),
      period: Keyword.get(opts, :period, @default_period_ms)
    }
  end

  def call(%Plug.Conn{request_path: path} = conn, %{limit: limit, period: period}) do
    if String.starts_with?(path, @path_prefix) do
      enforce(conn, effective_limit(limit), period)
    else
      conn
    end
  end

  defp enforce(conn, limit, period) do
    key = bucket_key(conn)

    case EngramWeb.RateLimiter.hit(key, period, limit) do
      {:allow, count} ->
        remaining = max(limit - count, 0)

        conn
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", Integer.to_string(remaining))

      {:deny, retry_after_ms} ->
        retry_after_s = retry_after_ms |> div(1000) |> max(1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("x-engram-error", "rate_limited")
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
        |> halt()
    end
  end

  # Test/CI override knob. Mirrors the `:rate_limit_override` pattern from
  # `EngramWeb.Plugs.RateLimit` but with a notes-specific app-env key so
  # adjustments to one limiter cannot accidentally relax the other.
  defp effective_limit(default) do
    Application.get_env(:engram, :notes_rate_limit_override) || default
  end

  defp bucket_key(conn) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    "notes:#{ip}:#{principal(conn)}"
  end

  # Cheap principal extraction with NO signature verification — see the
  # moduledoc; the value is used only as a bucket-segmenting key. Anything
  # we can't parse falls back to `anon` so it shares the IP-only bucket
  # with no-auth traffic.
  defp principal(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer engram_" <> rest] -> "key:" <> String.slice(rest, 0, 12)
      ["Bearer " <> token] -> jwt_sub(token)
      _ -> "anon"
    end
  end

  defp jwt_sub(token) do
    with [_h, payload_b64, _s] <- String.split(token, ".", parts: 3),
         {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, %{"sub" => sub}} when is_binary(sub) <- Jason.decode(payload_json) do
      "jwt:" <> sub
    else
      _ -> "anon"
    end
  end
end
