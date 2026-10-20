defmodule EngramWeb.Plugs.WebActivity do
  @moduledoc """
  Product analytics: counts a request as `:web` activity when it was
  authenticated by a Clerk session, i.e. the SPA.

  `Plugs.Auth` leaves no "credential type" assign, so the web case is the one
  with NEITHER marker: an API key sets `current_api_key`, and a device / OAuth /
  MCP token sets `current_auth_method: :internal_jwt`. The legacy HS256 JWT
  also lands in the unmarked branch and is counted as web; nothing but the SPA
  should still send one.

  Throttling (one event per user per 5 minutes) lives in
  `Engram.Analytics.track_activity/3`, so this is safe on every request.

  Also reports a 409, 413 or 426 response as `sync_error{kind, surface}`,
  throttled per user and kind in `Engram.Analytics.track_sync_error/3`.
  """

  @sync_errors %{409 => "conflict", 413 => "too_large", 426 => "upgrade_required"}

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user} = assigns} = conn, _opts) do
    surface = surface(assigns)
    if surface == "web", do: Engram.Analytics.track_activity(user, :web)

    # The one place every authenticated response passes, so the refusals a
    # sync client retries on (scattered over a dozen controllers and plugs
    # downstream) are counted without touching each of them.
    Plug.Conn.register_before_send(conn, fn conn ->
      case Map.fetch(@sync_errors, conn.status) do
        {:ok, kind} -> Engram.Analytics.track_sync_error(user, kind, %{surface: surface})
        :error -> :ok
      end

      conn
    end)
  end

  def call(conn, _opts), do: conn

  @doc """
  The analytics surface of a REST request's credential: `"api"` for an API
  key, `"obsidian_sync"` for a device / OAuth token (MCP has its own
  controller), `"web"` for a Clerk session.
  """
  @spec surface(map()) :: String.t()
  def surface(assigns) do
    cond do
      Map.get(assigns, :current_api_key) -> "api"
      Map.get(assigns, :current_auth_method) == :internal_jwt -> "obsidian_sync"
      true -> "web"
    end
  end
end
