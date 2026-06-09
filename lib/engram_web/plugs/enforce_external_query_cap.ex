defmodule EngramWeb.Plugs.EnforceExternalQueryCap do
  @moduledoc """
  Free-tier abuse defense — rolling-24h cap on programmatic ("external
  tooling") API queries. Catches both 3rd-party MCP / OAuth clients and
  the user's own non-app tooling (Obsidian plugin device-flow, PAT
  scripts). Web-SPA Clerk-JWT traffic is exempt.

  Reads the per-user effective limit from
  `Engram.Billing.effective_limit(user, :external_queries_per_day)` and
  defers counting to `EngramWeb.RateLimiter.hit/3` with a 24h window.
  `nil` (Starter / Pro default) → no enforcement.

  On deny: HTTP 402 via `EngramWeb.LimitResponse` so the UpgradeDialog
  surface routes it the same way every other 402 cap rejection does.
  """

  import Plug.Conn

  alias Engram.Billing
  alias EngramWeb.{LimitResponse, RateLimiter}

  # 24h rolling window — Hammer slides automatically. Use ms so the call
  # signature matches the existing RPS-budget plug.
  @period_ms 86_400_000

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: assigns} = conn, _opts) do
    if external_tooling?(assigns), do: enforce(conn, assigns.current_user), else: conn
  end

  # API key (PAT) OR internal-JWT (device-flow / OAuth / MCP) → external.
  # The web SPA authes via a Clerk JWT and reaches downstream plugs with
  # NEITHER marker set, so it falls into the exempt branch.
  defp external_tooling?(%{current_api_key: _}), do: true
  defp external_tooling?(%{current_auth_method: :internal_jwt}), do: true
  defp external_tooling?(_), do: false

  defp enforce(conn, user) do
    case Billing.effective_limit(user, :external_queries_per_day) do
      :unlimited -> conn
      nil -> conn
      limit when is_integer(limit) and limit > 0 -> check(conn, user, limit)
      0 -> deny(conn, 0, 0)
      _ -> conn
    end
  end

  defp check(conn, user, limit) do
    case RateLimiter.hit("ext_q:#{user.id}", @period_ms, limit) do
      {:allow, _count} -> conn
      {:deny, _retry_after_ms} -> deny(conn, limit, limit)
    end
  end

  defp deny(conn, limit, current) do
    LimitResponse.halt(
      conn,
      "external_queries_per_day_exceeded",
      :external_queries_per_day,
      limit,
      current
    )
  end
end
