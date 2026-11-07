defmodule EngramWeb.WriteActor do
  @moduledoc """
  The history actor for a REST note write (#1710).

  An API key is its own actor, so a script's edits form versions separate from
  yours. Every other authenticated REST client (the web app, the plugin's
  device-flow token) is the user's own client, the same actor as their CRDT
  edits. MCP does not come through here; `Engram.MCP.Handlers` passes "mcp".
  """
  alias EngramWeb.RequestMeta

  @spec for_conn(Plug.Conn.t()) :: String.t()
  def for_conn(%Plug.Conn{assigns: %{current_api_key: %{id: id}}}), do: "api:#{id}"
  def for_conn(%Plug.Conn{}), do: "sync"

  @doc """
  Whether a REST write must declare `base_hash` to replace an existing note
  (`Notes.upsert_note/4`'s `require_base:`, #2480).

  True for the external callers a stale read hurts: an API key or an MCP
  OAuth token used against REST. False for the user's own sync clients:

    * session and device-flow tokens (the web app, a linked plugin) are not
      `"api"`/`"mcp"` surfaces at all;
    * the Obsidian plugin can also run on an API key. Every shipped version
      pushes whole notes without a base (reconnect, offline queue) and none
      can be force-upgraded, so a caller that reports `X-Plugin-Version`
      (1.29.0+) or that the Obsidian app's user agent names (older plugins
      send no version header) is exempt.

  This is a data-safety accident guard for honest clients, NOT a security
  boundary. Both signals are self-reported: a caller that spoofs them only
  opts out of its own stale-write protection. It skips nothing
  security-relevant: auth, tenancy (RLS), rate limits and plan limits all run
  before and regardless of this check.
  """
  @spec requires_base?(Plug.Conn.t()) :: boolean()
  def requires_base?(%Plug.Conn{} = conn) do
    RequestMeta.surface(conn.assigns) in ["api", "mcp"] and
      Plug.Conn.get_req_header(conn, "x-plugin-version") == [] and
      not obsidian_user_agent?(conn)
  end

  # compat(plugin): no-version blind push exemption - remove when plugin floor >= 1.29.0 (#2480)
  # Plugins before 1.29.0 send no X-Plugin-Version, so the version floor
  # cannot see them yet (a missing header passes RequirePluginVersion); only
  # their user agent names them. Desktop is Electron ("obsidian/1.15.0"),
  # iOS is "Obsidian/396 CFNetwork", Android's native HTTP is "Dalvik/" (any
  # Android app; accepted, this guard is not security). Measured in prod
  # Tempo 2026-10-31..11-06: every POST /api/notes but a few "node" and
  # "Python-urllib" calls carried one of these.
  @obsidian_ua ~r/obsidian\/|^Dalvik\//i

  defp obsidian_user_agent?(conn) do
    Enum.any?(Plug.Conn.get_req_header(conn, "user-agent"), &Regex.match?(@obsidian_ua, &1))
  end
end
