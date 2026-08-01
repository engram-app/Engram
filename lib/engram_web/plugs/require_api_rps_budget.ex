defmodule EngramWeb.Plugs.RequireApiRpsBudget do
  @moduledoc """
  Pricing v2 §G — per-plan RPS cap on authenticated API requests.

  Looks up the user's `api_rps_cap` from `Engram.Billing` and rate-limits
  via `EngramWeb.RateLimiter` with a 1-second window. JWT-authed requests
  (web app) are exempt; the gate only fires for API-key-authed traffic,
  mirroring the policy shape in `RequireApiWriteEnabled`.

  Free defaults to `0` (no API access). Starter `10`, Pro `30`. When the
  cap is exhausted within the window, responds 429 with
  `{"error": "api_rps_exceeded", "limit": N, "period_ms": 1000}`.

  Self-host with `ENGRAM_LIMITS_ENFORCED=false` short-circuits to
  `:unlimited` via `Billing.effective_limit/2` — no rate-limiter call.
  """

  import Plug.Conn

  alias Engram.Billing

  @default_period_ms 1_000

  # The window LENGTH is configuration, not the behaviour under test: what the
  # gate promises is "N requests per window, then 429". Hammer derives its
  # bucket from wall-clock (`div(now_ms, scale_ms)`), so a test that fires N+1
  # calls against a 1 s window is racing a real second boundary — under load the
  # warm-up calls straddle it, the bucket resets, and the call that should be
  # denied is back under cap (#1080 / #936, observed 1/3785 in CI).
  #
  # Widening the window in tests removes the race outright rather than papering
  # over it: all N+1 calls land in ONE bucket by construction, with no timing
  # assumption left to lose. Prod never sets this. Same shape as the
  # `:crdt_msg_rate_limit_override` seam in CrdtChannel.
  defp period_ms do
    Application.get_env(:engram, :api_rps_period_ms, @default_period_ms)
  end

  def init(opts), do: opts

  # JWT-authed (no API key) is exempt — web app is not subject to this gate.
  def call(%Plug.Conn{assigns: assigns} = conn, _opts)
      when not is_map_key(assigns, :current_api_key),
      do: conn

  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
    case Billing.effective_limit(user, :api_rps_cap) do
      :unlimited -> conn
      nil -> conn
      0 -> deny(conn, 0)
      limit when is_integer(limit) and limit > 0 -> check_rate_limit(conn, user, limit)
      _ -> conn
    end
  end

  defp check_rate_limit(conn, user, limit) do
    case EngramWeb.RateLimiter.hit("api_rps:#{user.id}", period_ms(), limit, :api_rps) do
      {:allow, _count} -> conn
      {:deny, _retry_after_ms} -> deny(conn, limit)
    end
  end

  defp deny(conn, limit) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(%{
        error: "api_rps_exceeded",
        limit: limit,
        period_ms: period_ms()
      })
    )
    |> halt()
  end
end
