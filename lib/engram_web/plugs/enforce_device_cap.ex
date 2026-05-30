defmodule EngramWeb.Plugs.EnforceDeviceCap do
  @moduledoc """
  Mounted on `POST /api/auth/device/authorize` — the user-confirming action
  that, on success, causes the next `/api/auth/device/token` poll to mint a
  device refresh token. Halts 402 if the user is already at their per-tier
  `obsidian_connections_cap`.

  Distinct from `EnforceConnectionCap`, which gates MCP OAuth consent
  (`oauth_authorizations`). Both consult `obsidian_connections_cap` /
  `mcp_connections_cap` LimitKeys; this plug always uses the obsidian key
  because device flow only serves the Obsidian plugin today.

  ## Race note

  Two concurrent authorize POSTs at cap−1 can both pass and mint two
  device refresh tokens, briefly exceeding cap by one. Acceptable trade-off
  for a low-frequency user action; consistent with the same note in
  `EnforceConnectionCap`.
  """

  import Plug.Conn
  alias Engram.{Billing, Connections}

  @upgrade_url "/settings/billing"

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
    limit = Billing.effective_limit(user, :obsidian_connections_cap)
    current = Connections.count_active(user.id, :obsidian)

    cond do
      limit in [:unlimited, nil] ->
        conn

      is_integer(limit) and current < limit ->
        conn

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          402,
          Jason.encode!(%{
            error: "connection_cap_reached",
            kind: "obsidian",
            current: current,
            limit: limit,
            upgrade_url: @upgrade_url
          })
        )
        |> halt()
    end
  end

  def call(_conn, _opts) do
    raise "EnforceDeviceCap requires :current_user assigned by upstream auth plug"
  end
end
