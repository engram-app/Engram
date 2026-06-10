defmodule EngramWeb.Plugs.HostRewrite do
  @moduledoc """
  Host-driven path rewrite for the dedicated `api.engram.page` and
  `mcp.engram.page` saas hosts. The same Phoenix endpoint also serves
  selfhost (`engram.ax`) and the canonical `app.engram.page` host without
  any rewrite. Behavior:

    * `api.engram.page` — prefix `/api` if the path doesn't already start
      with `/api`, `/socket`, `/webhooks`, or `/.well-known`. After rewrite,
      reject anything that would have resolved outside those scopes.
    * `mcp.engram.page` — pass `/.well-known/oauth-*` through unmodified;
      otherwise prefix `/api/mcp` if not already prefixed; reject anything
      that would resolve outside `/api/mcp/*` or `/.well-known/oauth-*`.
    * Any other host — passthrough.

  Config-driven via `Application.get_env(:engram, :host_rewrite)`:

      config :engram, :host_rewrite, api_host: "api.engram.page", mcp_host: "mcp.engram.page"

  When unset (default), the plug is a strict no-op — selfhost releases never
  touch the rewrite path.
  """
  import Plug.Conn

  # Allowed top-level scopes that should pass through unmodified on
  # `api.engram.page`. Matched with `is_under?/2` (exact match OR followed
  # by `/`) so `/api-keys` does NOT match `/api` — `/api-keys` is a deep
  # API candidate that needs rewriting to `/api/api-keys`.
  @api_allowed_prefixes ~w(/api /socket /webhooks /.well-known)
  # Every top-level segment under `scope "/api", EngramWeb` in router.ex.
  # Missing entries silently 404 in prod — guarded by a regression test.
  @api_top_segments ~w(
    notes folders search vaults attachments oauth mcp auth admin billing
    tasks health user me onboarding api-keys connections tags sync logs
    embed-status
  )

  def init(opts), do: opts |> Keyword.put_new(:api_host, nil) |> Keyword.put_new(:mcp_host, nil)

  def call(conn, opts) do
    api_host = opts[:api_host]
    mcp_host = opts[:mcp_host]

    cond do
      api_host && conn.host == api_host -> handle_api_host(conn)
      mcp_host && conn.host == mcp_host -> handle_mcp_host(conn)
      true -> conn
    end
  end

  defp handle_api_host(conn) do
    path = conn.request_path

    cond do
      path == "/" or path == "" -> reject(conn)
      under_any?(path, @api_allowed_prefixes) -> conn
      not deep_api_candidate?(path) -> reject(conn)
      true -> rewrite_path(conn, "/api" <> path)
    end
  end

  @mcp_wellknown_prefixes [
    "/.well-known/oauth-protected-resource",
    "/.well-known/oauth-authorization-server"
  ]

  defp handle_mcp_host(conn) do
    path = conn.request_path

    cond do
      Enum.any?(@mcp_wellknown_prefixes, &String.starts_with?(path, &1)) -> conn
      String.starts_with?(path, "/api/mcp") -> conn
      path == "/" or path == "" -> rewrite_path(conn, "/api/mcp/")
      true -> reject(conn)
    end
  end

  defp under_any?(path, prefixes), do: Enum.any?(prefixes, &is_under?(path, &1))

  # True when `path` equals `prefix` or starts with `prefix <> "/"`.
  # Distinguishes `/api/...` (true) from `/api-keys` (false).
  defp is_under?(path, prefix),
    do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp deep_api_candidate?(path) do
    case String.split(path, "/", trim: true) do
      [head | _] -> head in @api_top_segments
      _ -> false
    end
  end

  defp rewrite_path(conn, new_path) do
    new_info = new_path |> String.trim_leading("/") |> String.split("/", trim: true)
    %{conn | request_path: new_path, path_info: new_info}
  end

  defp reject(conn) do
    conn
    |> send_resp(404, "Not Found")
    |> halt()
  end
end
