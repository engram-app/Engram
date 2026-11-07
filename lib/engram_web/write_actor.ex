defmodule EngramWeb.WriteActor do
  @moduledoc """
  The history actor for a REST note write (#1710).

  An API key is its own actor, so a script's edits form versions separate from
  yours. Every other authenticated REST client (the web app, the plugin's
  device-flow token) is the user's own client, the same actor as their CRDT
  edits. MCP does not come through here; `Engram.MCP.Handlers` passes "mcp".
  """
  @spec for_conn(Plug.Conn.t()) :: String.t()
  def for_conn(%Plug.Conn{assigns: %{current_api_key: %{id: id}}}), do: "api:#{id}"
  def for_conn(%Plug.Conn{}), do: "sync"

  @doc """
  Whether a REST write must declare `base_hash` to replace an existing note
  (`Notes.upsert_note/4`'s `require_base:`, #2480).

  True for the external callers a stale read hurts: an API key or an MCP
  OAuth token used against REST. False for the user's own sync clients. The
  web app and the device-flow plugin authenticate with session or plugin
  tokens, and the Obsidian plugin can also run on an API key, so a caller
  that reports `X-Plugin-Version` is exempt: shipped plugins push whole notes
  without a base (reconnect, offline queue) and cannot be force-upgraded.
  The header is self-reported, so this is a guard against honest stale
  writes, not an access control.
  """
  @spec requires_base?(Plug.Conn.t()) :: boolean()
  def requires_base?(%Plug.Conn{} = conn) do
    EngramWeb.RequestMeta.surface(conn.assigns) in ["api", "mcp"] and
      Plug.Conn.get_req_header(conn, "x-plugin-version") == []
  end
end
