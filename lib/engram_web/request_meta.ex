defmodule EngramWeb.RequestMeta do
  @moduledoc """
  Helpers for extracting client metadata (IP, user agent, the credential's
  surface, the matched route) from a `%Plug.Conn{}`, to stamp on database rows
  for provenance (DCR registrations, onboarding agreements, etc) and on log
  lines and analytics events.
  """

  @mcp_audience Engram.Token.mcp_audience()

  @doc """
  The analytics surface of a request's credential, from its assigns: `"api"`
  for an API key, `"mcp"` for an MCP-audience OAuth token, `"obsidian_sync"`
  for a device token, `"web"` for a Clerk session.

  The one credential-to-surface rule; analytics and log lines both read it.
  `Plugs.Auth` leaves no "credential type" assign, so the web case is the one
  with no marker at all. The legacy HS256 JWT lands there too.
  """
  @spec surface(map()) :: String.t()
  def surface(assigns) do
    cond do
      Map.get(assigns, :current_api_key) -> "api"
      mcp_claims(assigns) -> "mcp"
      Map.get(assigns, :current_auth_method) == :internal_jwt -> "obsidian_sync"
      true -> "web"
    end
  end

  @doc """
  `surface/1` for a log line: an MCP request also names its OAuth client
  (`"mcp:<client_id>"`, the `oauth_clients` key), so one stuck connector is
  findable. Analytics keeps the bare enum.
  """
  @spec log_surface(map()) :: String.t()
  def log_surface(assigns) do
    case mcp_claims(assigns) do
      %{"client_id" => client_id} when is_binary(client_id) -> "mcp:" <> client_id
      %{} -> "mcp:unknown"
      nil -> surface(assigns)
    end
  end

  # `Plugs.Auth` assigns `{:ok, claims}` for a token that carries a grant
  # (under either JWT provider), `:error` otherwise.
  defp mcp_claims(%{grant_claims: {:ok, %{"aud" => @mcp_audience} = claims}}), do: claims
  defp mcp_claims(_assigns), do: nil

  @doc """
  The matched route as `"Module#action"`, or nil. Fixed by the route table,
  so it never carries user data, unlike `request_path`.

  `phoenix_controller` is only set once the controller runs, so a request a
  router pipeline plug halted (`RequireOnboarding`'s 403) resolves through
  the route table of the router that ran. Nil when no router ran (static
  assets, endpoint plugs).
  """
  @spec log_route(Plug.Conn.t()) :: String.t() | nil
  def log_route(%Plug.Conn{private: %{phoenix_controller: controller, phoenix_action: action}})
      when is_atom(controller) and controller != nil and is_atom(action) and action != nil,
      do: "#{inspect(controller)}##{action}"

  def log_route(%Plug.Conn{private: %{phoenix_router: router}} = conn),
    do: route_name(Phoenix.Router.route_info(router, conn.method, conn.path_info, conn.host))

  def log_route(%Plug.Conn{}), do: nil

  @doc "`log_route/1`'s `\"Module#action\"` from a `Phoenix.Router.route_info/4` result."
  @spec route_name(map() | :error) :: String.t() | nil
  def route_name(%{plug: plug, plug_opts: action}) when is_atom(action),
    do: "#{inspect(plug)}##{action}"

  def route_name(_), do: nil

  @spec format_ip(:inet.ip_address() | term()) :: String.t() | nil
  def format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  def format_ip(tuple) when is_tuple(tuple) and tuple_size(tuple) == 8 do
    tuple |> :inet.ntoa() |> to_string()
  end

  def format_ip(_), do: nil

  @spec get_user_agent(Plug.Conn.t()) :: String.t() | nil
  def get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end

  # The user agent is attacker-controlled, RedactFilter neither scrubs nor
  # bounds `:user_agent`, and prod serializes all metadata: with Bandit's
  # 10_000-byte header cap, an unbounded one is ~10 KB of arbitrary text per
  # request in a long-retention aggregator. 200 chars holds every real UA (the
  # Obsidian one is ~120) and nothing else. Bytes, not graphemes: one grapheme
  # can carry thousands of combining marks.
  @user_agent_log_limit 200

  @doc "The user agent, bounded for a log line or metadata. Nil when absent."
  @spec log_user_agent(Plug.Conn.t()) :: String.t() | nil
  def log_user_agent(conn) do
    case get_user_agent(conn) do
      nil -> nil
      ua -> String.byte_slice(ua, 0, @user_agent_log_limit)
    end
  end

  @doc """
  The request's `content-length` as an integer, or nil when absent. Bandit
  rejects a malformed header before any plug runs, so an unparseable value
  only reaches here from tests; it reads as undeclared.
  """
  @spec declared_length(Plug.Conn.t()) :: non_neg_integer() | nil
  def declared_length(conn) do
    with [value | _] <- Plug.Conn.get_req_header(conn, "content-length"),
         {n, ""} <- Integer.parse(value) do
      n
    else
      _ -> nil
    end
  end
end
