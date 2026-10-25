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
  alias Engram.Crypto.RotationInProgressError
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
        # encrypts under the user's DEK, so it must see the lock fresh; reads
        # keep the cached answer. An MCP request is always a POST, so it is a
        # read when its JSON-RPC body says so.
        cond do
          mcp_read?(conn) ->
            conn

          # MCP turns a raise into a JSON-RPC error, so it reads the lock here.
          conn.path_info == ["api", "mcp"] ->
            case RotationGate.check(user_id) do
              {:error, :rotation_in_progress} -> halt_rotating(conn)
              _ -> conn
            end

          # REST: the write's own tenant transaction reads the lock in its
          # tenant_enter (RotationGate.gated/1), one round trip fewer, and a
          # locked user's write raises RotationInProgressError (503) before it
          # writes anything.
          true ->
            gate_request(conn)
        end

      _ ->
        conn
    end
  end

  # Fails closed: only a known read-only tool or a method that runs no tool.
  # A batch, an unknown method or an unknown tool name is a write.
  # Every non-tool method EngramWeb.MCPController dispatches is a read.
  @mcp_read_methods ~w(initialize ping server/discover tools/list prompts/list prompts/get
                       resources/list resources/read resources/templates/list
                       completion/complete)

  defp mcp_read?(%Plug.Conn{path_info: ["api", "mcp"], body_params: body}) do
    case body do
      %{"method" => "tools/call", "params" => %{"name" => name}} -> Tools.read_only?(name)
      %{"method" => method} -> method in @mcp_read_methods
      _ -> false
    end
  end

  defp mcp_read?(_conn), do: false

  # The gate is process state, and a keep-alive connection serves its next
  # request from the same process, so the response clears it. The before_send
  # also gives a rotation refusal's 503 its 60s Retry-After (the error renderer
  # sets no headers, and assigns the raised error as `:reason`). Any other 503
  # keeps `EngramWeb.Plugs.RetryAfter`'s.
  defp gate_request(conn) do
    Process.put(:engram_write_gate, true)

    register_before_send(conn, fn conn ->
      Process.delete(:engram_write_gate)

      if match?(%RotationInProgressError{}, conn.assigns[:reason]) and
           get_resp_header(conn, "retry-after") == [],
         do: put_resp_header(conn, "retry-after", "60"),
         else: conn
    end)
  end

  @doc """
  The 503 every rotation refusal answers with. Also used by write paths that
  hit the lock after this plug let the request through.
  """
  @spec halt_rotating(Plug.Conn.t()) :: Plug.Conn.t()
  def halt_rotating(conn) do
    conn
    |> put_resp_header("retry-after", "60")
    |> Halt.json(503, %{error: "rotation_in_progress"})
  end
end
