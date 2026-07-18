defmodule EngramWeb.Plugs.DrainConnClose do
  @moduledoc """
  While the node is draining (SIGTERM received, `Engram.Drainer.drain/1`
  started), stamp `connection: close` on every HTTP response so clients stop
  reusing keep-alive connections to a task that is about to disappear.

  Without this, a pooled connection dies half-open under the client mid-deploy
  and its next request hangs to the full client deadline (the plugin #244
  wedged-request class). Bandit honors the response header and closes the
  connection after the response, so the client's next request opens a fresh
  connection — routed by the ALB to a live task. Outside the drain window this
  plug is a single :persistent_term read.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Engram.Drainer.draining?() do
      Plug.Conn.put_resp_header(conn, "connection", "close")
    else
      conn
    end
  end
end
