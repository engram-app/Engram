defmodule EngramWeb.Plugs.PreAuthRateLimit do
  @moduledoc """
  Application-layer rate limiter defending the vault-scoped pipeline against
  401-loop attacks. Defense-in-depth for the Cloudflare ruleset dropped in
  engram-infra#361 — the Free CF tier cannot count response-conditional
  (auth-rejected) requests, so this plug picks up the slack.

  ## Placement

  This plug MUST run **before** `EngramWeb.Plugs.Auth`. The whole point is
  that requests rejected by auth (bad JWT, expired, etc.) still consume bucket
  capacity — otherwise an attacker can hammer the API forever with any garbage
  Bearer token. Mounted on the vault-scoped pipeline in `EngramWeb.Router`; it
  protects every route there (`/api/notes`, `/api/search`, `/api/folders`,
  `/api/tags`, `/api/attachments`, `/api/logs`, `/api/sync`, `/api/mcp`, …),
  not just `/api/notes`.

  ## Bucket key

  `preauth:<path-category>:<ip>:<sub-or-anon>`

  * `path-category` — the first two path segments (e.g. `api/notes`,
    `api/search`). Each endpoint family gets its own bucket, so the limit on
    one cannot starve another and a heavy multi-endpoint sync isn't squeezed
    into a single shared budget. Keying on the *category* (not the full path)
    keeps all of `/api/notes/*` in one bucket, so an attacker can't mint fresh
    buckets by varying the trailing path.
  * `ip` — the real client IP via `EngramWeb.RemoteIp` (the trusted
    CF-Connecting-IP in prod, else the raw socket IP; never the spoofable
    `x-forwarded-for`).
  * `sub` — the unverified `sub` claim from the Bearer JWT, OR `anon` if there
    is no JWT or the token is malformed. The signature is NOT verified; the
    claim is a bucket key only, granting no authority. This keeps a legitimate
    user's bucket distinct from anonymous traffic on a shared NAT/egress IP,
    while the IP fallback still catches a stream of garbage tokens from one
    attacker host. API keys (`Bearer engram_*`) bucket by prefix so one
    rotated key can't starve a sibling on the same host.

  ## Limits

  Defaults: 600 req per 60s sliding window per bucket. Override via
  `Application.get_env(:engram, :pre_auth_rate_limit_override, integer)` for
  CI / load tests / regional adjustments. This is a coarse net for the
  unauthenticated 401-loop case, not per-plan policy — the authenticated
  `RequireApiRpsBudget` enforces per-plan RPS downstream.

  ## Response on overage

  HTTP 429 + JSON `{"error":"rate_limited"}` plus `Retry-After`,
  `X-RateLimit-Limit`, and `X-RateLimit-Remaining: 0`. Allowed responses also
  carry the limit/remaining headers so well-behaved clients self-throttle.
  """

  import Plug.Conn

  @default_limit 600
  @default_period_ms 60_000

  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, @default_limit),
      period: Keyword.get(opts, :period, @default_period_ms)
    }
  end

  def call(%Plug.Conn{} = conn, %{limit: limit, period: period}) do
    enforce(conn, effective_limit(limit), period)
  end

  defp enforce(conn, limit, period) do
    key = bucket_key(conn)

    case EngramWeb.RateLimiter.hit(key, period, limit, :preauth) do
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

  # Test/CI override knob. Mirrors `:rate_limit_override` but with its own
  # app-env key so adjusting one limiter cannot relax the other.
  defp effective_limit(default) do
    Application.get_env(:engram, :pre_auth_rate_limit_override) || default
  end

  defp bucket_key(conn) do
    ip = conn |> EngramWeb.RemoteIp.resolve() |> :inet.ntoa() |> to_string()
    "preauth:#{path_category(conn)}:#{ip}:#{principal(conn)}"
  end

  # First two path segments — coarse enough that `/api/notes/foo` and
  # `/api/notes/bar` share a bucket (an attacker can't mint fresh buckets by
  # varying the trailing path), distinct enough that `/api/search` and
  # `/api/notes` don't compete for the same budget.
  defp path_category(conn) do
    conn.path_info |> Enum.take(2) |> Enum.join("/")
  end

  # Cheap principal extraction with NO signature verification — see moduledoc;
  # the value is a bucket-segmenting key only. Anything unparseable falls back
  # to `anon` so it shares the IP-only bucket with no-auth traffic.
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
