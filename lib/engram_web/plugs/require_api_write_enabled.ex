defmodule EngramWeb.Plugs.RequireApiWriteEnabled do
  @moduledoc """
  Pricing v2 §G — gate non-GET API requests on the user's
  `api_write_enabled` plan flag, but only when the request was authed via
  API key. JWT-authed (web app) requests bypass this gate; the web UI is
  expected to disable write affordances for tiers that lack the feature.

  Free's default is `api_write_enabled = false` — Starter and Pro both
  default `true`. Rejection: HTTP 402 with
  `{"error": "api_write_not_available", "upgrade_url": "/settings/billing"}`.

  POST `/api/search` is explicitly exempt: it's a read despite being a
  POST (encrypted query body). All other non-GET routes on the
  vault-scoped pipeline are gated.
  """

  import Plug.Conn

  alias Engram.Billing

  @read_post_paths ~w(/api/search)

  def init(opts), do: opts

  # Reads are never gated.
  def call(%Plug.Conn{method: m} = conn, _opts) when m in ["GET", "HEAD"], do: conn

  # JWT-authed (no API key resolved) → web app path → exempt.
  def call(%Plug.Conn{assigns: assigns} = conn, _opts)
      when not is_map_key(assigns, :current_api_key) do
    conn
  end

  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in @read_post_paths, do: conn

  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
    case Billing.check_feature(user, :api_write_enabled) do
      :ok ->
        conn

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          402,
          Jason.encode!(%{
            error: "api_write_not_available",
            upgrade_url: "/settings/billing"
          })
        )
        |> halt()
    end
  end
end
