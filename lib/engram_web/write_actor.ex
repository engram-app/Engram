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
end
