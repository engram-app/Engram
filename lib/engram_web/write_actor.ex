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
      (1.29.0+) is exempt. A plugin older than that sends no version and is
      refused before reaching a controller (`RequirePluginVersion` treats an
      Obsidian user agent with no version as below the floor), so it needs no
      exemption here.

  This is a data-safety accident guard for honest clients, NOT a security
  boundary. The signal is self-reported: a caller that spoofs it only opts
  out of its own stale-write protection. It skips nothing
  security-relevant: auth, tenancy (RLS), rate limits and plan limits all run
  before and regardless of this check.
  """
  @spec requires_base?(Plug.Conn.t()) :: boolean()
  def requires_base?(%Plug.Conn{} = conn) do
    RequestMeta.surface(conn.assigns) in ["api", "mcp"] and not plugin_client?(conn)
  end

  @doc """
  Whether the caller says it is the Obsidian plugin: it reports
  `X-Plugin-Version` (1.29.0+). An Obsidian user agent without it never gets
  here: `RequirePluginVersion` refuses it as below the floor. Self-reported,
  so it must never grant anything security-relevant.
  """
  @spec plugin_client?(Plug.Conn.t()) :: boolean()
  def plugin_client?(%Plug.Conn{} = conn) do
    Plug.Conn.get_req_header(conn, "x-plugin-version") != []
  end
end
