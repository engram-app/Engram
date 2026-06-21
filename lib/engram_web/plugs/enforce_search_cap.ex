defmodule EngramWeb.Plugs.EnforceSearchCap do
  @moduledoc """
  Free-tier abuse defense — rolling-24h cap on POST /api/search. Split
  into two distinct buckets so an automated MCP / PAT client can't burn
  the user's in-app budget and vice-versa:

    * `external_ai_searches_per_day` — PAT, OAuth, device-flow, MCP
    * `inapp_searches_per_day`       — Web SPA (Clerk JWT, no markers)

  Both caps live in `Engram.Billing.LimitKeys`. A `nil` (Starter / Pro
  default) means no enforcement. On deny: 402 via
  `EngramWeb.LimitResponse` so the UpgradeDialog surface routes the
  reason like any other plan limit.

  Fires only for `POST /api/search` — note reads, manifest pulls,
  attachment fetches are not counted. Other endpoints pass through
  untouched, so this plug can sit on a broad pipeline cheaply.
  """

  alias Engram.Billing
  alias EngramWeb.LimitResponse

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", request_path: "/api/search"} = conn, _opts) do
    user = conn.assigns.current_user

    case cap_kind(conn.assigns) do
      :external -> enforce_external(conn, user)
      :inapp -> enforce_inapp(conn, user)
    end
  end

  def call(conn, _opts), do: conn

  # PAT (API key) OR internal JWT (device-flow / OAuth / MCP) → external.
  # Anything else (Clerk JWT, web SPA) → in-app. Pure routing — the
  # branches below pin the cap key as a literal so the
  # `engram.lint.limit_keys` static check is satisfied.
  defp cap_kind(%{current_api_key: _}), do: :external
  defp cap_kind(%{current_auth_method: :internal_jwt}), do: :external
  defp cap_kind(_), do: :inapp

  defp enforce_external(conn, user) do
    case Billing.effective_limit(user, :external_ai_searches_per_day) do
      :unlimited ->
        conn

      nil ->
        conn

      0 ->
        deny(conn, :external_ai_searches_per_day, 0)

      limit when is_integer(limit) and limit > 0 ->
        check(conn, user, :external_ai_searches_per_day, "ext_search", limit)

      _ ->
        conn
    end
  end

  defp enforce_inapp(conn, user) do
    case Billing.effective_limit(user, :inapp_searches_per_day) do
      :unlimited ->
        conn

      nil ->
        conn

      0 ->
        deny(conn, :inapp_searches_per_day, 0)

      limit when is_integer(limit) and limit > 0 ->
        check(conn, user, :inapp_searches_per_day, "inapp_search", limit)

      _ ->
        conn
    end
  end

  # Token-bucket: capacity = daily allowance, refill = allowance/86_400 per sec
  # → continuous regeneration, no reset cliff, no cron. Durable in Postgres.
  defp check(conn, user, key, bucket_kind, limit) do
    case Engram.Usage.DailyCap.spend(user.id, bucket_kind, limit, limit / 86_400) do
      {:allow, _left} -> conn
      {:deny, _retry} -> deny(conn, key, limit)
    end
  end

  defp deny(conn, key, limit) do
    LimitResponse.halt(conn, reason_for(key), key, limit, limit)
  end

  defp reason_for(:external_ai_searches_per_day), do: "external_ai_searches_per_day_exceeded"
  defp reason_for(:inapp_searches_per_day), do: "inapp_searches_per_day_exceeded"
end
