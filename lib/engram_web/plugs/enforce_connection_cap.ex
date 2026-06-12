defmodule EngramWeb.Plugs.EnforceConnectionCap do
  @moduledoc """
  Mounted on `POST /api/oauth/authorize/consent`. Before minting a new
  refresh-token family, looks up the target `oauth_clients.kind`, counts
  the user's active grants of that kind, and halts 402 if minting one
  more would exceed the per-tier cap.

  The cap key is derived from kind: `:obsidian_connections_cap` or
  `:mcp_connections_cap`. Free defaults to 1 of each; paid tiers default
  to nil (unlimited).

  Rejection body:
      {"error": "limit_exceeded",
       "reason": "<obsidian|mcp>_connections_exceeded",
       "limit_key": "<obsidian|mcp>_connections_cap",
       "tier": "free" | "starter" | "pro",
       "current": <integer>,
       "limit": <integer>,
       "upgrade_url": "/settings/billing"}

  Missing or unknown `client_id`: HTTP 400 with
      {"error": "missing_or_invalid_client_id"}

  Refresh-token rotation does NOT come through this plug — rotation
  consumes the old token in `Engram.OAuth.exchange_refresh_token/2`
  without adding a new connection, so caps are not re-checked on every
  request.

  ## Known limitations

  Two concurrent consent POSTs at cap−1 can both pass the check and mint
  two grants, briefly exceeding the cap by one. This is an acceptable
  trade-off for a low-frequency user action; a DB-level atomic check or
  advisory lock would protect against this but would complicate the read
  path. Document tracked in the design spec.
  """

  import Plug.Conn
  import Ecto.Query

  alias Engram.{Billing, Connections, Repo}
  alias Engram.OAuth.Client

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user}, params: params} = conn, _opts) do
    case lookup_client(params) do
      {:ok, %Client{kind: kind_str}} ->
        case cap_for_user(user, kind_str) do
          :unlimited ->
            conn

          nil ->
            conn

          # -1 is the canonical "unlimited" sentinel — same convention as
          # Engram.Billing.check_limit/3 and BillingController.cap_json/1.
          -1 ->
            conn

          limit when is_integer(limit) ->
            current = Connections.count_active(user.id, kind_atom(kind_str))

            # Telemetry breadcrumb for the TOCTOU race documented above: when
            # current == limit - 1, two concurrent consents can both pass.
            # Emitting here lets us measure the race frequency before paying
            # the cost of an advisory lock.
            if current == limit - 1 do
              :telemetry.execute(
                [:engram, :connections, :near_cap],
                %{current: current, limit: limit},
                %{user_id: user.id, kind: kind_str}
              )
            end

            if current < limit do
              conn
            else
              reason = "#{kind_str}_connections_exceeded"
              EngramWeb.LimitResponse.halt(conn, reason, limit_key_for(kind_str), limit, current)
            end
        end

      :error ->
        send_json(conn, 400, %{error: "missing_or_invalid_client_id"})
    end
  end

  def call(_conn, _opts) do
    raise "EnforceConnectionCap requires :current_user assigned by upstream auth plug"
  end

  # Map kind string to the atom used by Connections.count_active/2. Using a
  # literal map avoids String.to_existing_atom/1 failure when the atom hasn't
  # been touched yet in a given beam node (e.g. unit test isolation).
  defp kind_atom("obsidian"), do: :obsidian
  defp kind_atom("mcp"), do: :mcp

  defp limit_key_for("obsidian"), do: :obsidian_connections_cap
  defp limit_key_for("mcp"), do: :mcp_connections_cap

  # Resolve the billing cap for a user using literal LimitKey atoms so the
  # static lint can verify catalog membership at compile time. Unknown kinds
  # return :unlimited (falls open) and log a warning for observability.
  defp cap_for_user(user, "obsidian"),
    do: Billing.effective_limit(user, :obsidian_connections_cap)

  defp cap_for_user(user, "mcp"), do: Billing.effective_limit(user, :mcp_connections_cap)

  defp cap_for_user(_user, other) do
    require Logger

    Logger.warning(
      "EnforceConnectionCap: unknown oauth_clients.kind value #{inspect(other)} — passing through as unlimited"
    )

    :unlimited
  end

  defp lookup_client(%{"client_id" => client_id}) when is_binary(client_id) do
    case Ecto.UUID.cast(client_id) do
      {:ok, _} ->
        case Repo.one(from(c in Client, where: c.client_id == ^client_id),
               skip_tenant_check: true
             ) do
          nil -> :error
          client -> {:ok, client}
        end

      :error ->
        :error
    end
  end

  defp lookup_client(_), do: :error

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
