defmodule EngramWeb.Plugs.RotationLockCheck do
  @moduledoc """
  T3.7 — short-circuits requests for any user whose DEK rotation is
  in flight. Mounted on the authenticated API pipeline AFTER auth so
  `:current_user` is populated. Returns 503 with `Retry-After: 60`
  to signal a transient block, not a permanent failure.

  Read AND write paths block — see spec §6 (rotated rows on disk
  reference a `dek_version` whose master mapping has not yet been
  flipped, so any decrypt with the old DEK fails until the rotation
  completes).
  """

  import Plug.Conn

  alias Engram.Accounts.User
  alias Engram.Crypto.RotationGate
  alias Engram.MCP.Tools
  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, _opts) do
    case conn.assigns[:current_user] do
      %User{dek_rotation_locked_at: %DateTime{}} ->
        halt_rotating(conn)

      %User{id: user_id} when conn.method not in ["GET", "HEAD"] ->
        # `current_user` comes from the `:user` cache, so a lock taken on
        # another node is visible here only once its eviction lands. A write
        # encrypts under the user's DEK, so it re-reads the lock (one query);
        # reads keep the cached answer. An MCP request is always a POST, so
        # it is a read when its JSON-RPC body says so.
        if mcp_read?(conn) do
          conn
        else
          case RotationGate.check(user_id) do
            {:error, :rotation_in_progress} -> halt_rotating(conn)
            _ -> conn
          end
        end

      _ ->
        conn
    end
  end

  # Fails closed: only a known read-only tool or a method that runs no tool.
  # A batch, an unknown method or an unknown tool name is a write.
  @mcp_read_methods ~w(initialize ping server/discover tools/list)

  defp mcp_read?(%Plug.Conn{path_info: ["api", "mcp"], body_params: body}) do
    case body do
      %{"method" => "tools/call", "params" => %{"name" => name}} -> Tools.read_only?(name)
      %{"method" => method} -> method in @mcp_read_methods
      _ -> false
    end
  end

  defp mcp_read?(_conn), do: false

  defp halt_rotating(conn) do
    conn
    |> put_resp_header("retry-after", "60")
    |> Halt.json(503, %{error: "rotation_in_progress"})
  end
end
