defmodule Engram.Usage.SearchCap do
  @moduledoc """
  THE answer to "may this user run another search today?".

  Pricing v2 §D — rolling-24h search caps on the Free tier, split by where the
  request came from so a noisy MCP / PAT bot can't burn the user's in-app
  budget and vice-versa:

    * `external_ai_searches_per_day` — PAT, OAuth, device-flow, MCP
    * `inapp_searches_per_day`       — Web SPA (Clerk JWT, no markers)

  This module owns BOTH the bucket choice and the spend. It exists because the
  rule used to live inside `EngramWeb.Plugs.EnforceSearchCap`, guarded on
  `request_path: "/api/search"` — which silently exempted the entire MCP
  transport, the exact client class the external bucket was written for. MCP
  searches arrive as a JSON-RPC `tools/call` at `POST /api/mcp` and reach
  `Engram.Search.search/4` directly, so no path-shaped gate can ever see them.

  Every caller — the plug and `EngramWeb.McpController` — routes through
  `spend/2`. Keep it that way: a second copy of the bucket-kind branch is how
  the two transports drift apart again.

  Returns `:ok` or `{:denied, limit_key, limit}`. The RESPONSE is the caller's
  business (402 via `LimitResponse` on REST, JSON-RPC `-32_005` on MCP) — this
  module only decides.
  """

  alias Engram.Billing
  alias Engram.Usage.DailyCap

  @type result :: :ok | {:denied, atom(), non_neg_integer()}

  @doc """
  Spends one search token for `user`, choosing the bucket from `assigns`.

  Pass the conn's assigns (REST) or the MCP conn's assigns — the marker keys
  are set by `EngramWeb.Plugs.Auth` on both.
  """
  @spec spend(map(), Engram.Accounts.User.t()) :: result()
  def spend(assigns, user) do
    case cap_kind(assigns) do
      :external -> external(user)
      :inapp -> inapp(user)
    end
  end

  # PAT (API key) OR internal JWT (device-flow / OAuth / MCP) → external.
  # Anything else (Clerk JWT, web SPA) → in-app.
  defp cap_kind(%{current_api_key: _}), do: :external
  defp cap_kind(%{current_auth_method: :internal_jwt}), do: :external
  defp cap_kind(_), do: :inapp

  # The two branches pin the cap key as a literal so the
  # `engram.lint.limit_keys` static check is satisfied.
  defp external(user) do
    user
    |> Billing.effective_limit(:external_ai_searches_per_day)
    |> check(user, :external_ai_searches_per_day, "ext_search")
  end

  defp inapp(user) do
    user
    |> Billing.effective_limit(:inapp_searches_per_day)
    |> check(user, :inapp_searches_per_day, "inapp_search")
  end

  # A `0` cap denies without touching the bucket — capacity 0 would make
  # DailyCap's refill rate 0 and its retry hint meaningless.
  defp check(0, _user, key, _bucket_kind), do: {:denied, key, 0}

  defp check(limit, user, key, bucket_kind) when is_integer(limit) and limit > 0 do
    # Token-bucket: capacity = daily allowance, refill = allowance/86_400 per
    # sec → continuous regeneration, no reset cliff, no cron. Durable in
    # Postgres.
    case DailyCap.spend(user.id, bucket_kind, limit, limit / 86_400) do
      {:allow, _left} -> :ok
      {:deny, _retry} -> {:denied, key, limit}
    end
  end

  # `:unlimited` (enforcement off), `nil` (Starter / Pro default) and any
  # unexpected shape all mean "no ceiling". Fails OPEN deliberately: this is
  # abuse defense, not an authorization boundary, and a malformed override row
  # must not lock a paying user out of search.
  defp check(_other, _user, _key, _bucket_kind), do: :ok
end
