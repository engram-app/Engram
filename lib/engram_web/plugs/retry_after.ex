defmodule EngramWeb.Plugs.RetryAfter do
  @moduledoc """
  Gives every 503 a `Retry-After` when the response set none: a 503 is
  transient by definition, and the error renderer (a raised
  `Plug.Exception` with status 503, such as `Engram.Crypto.DekUnavailableError`)
  sets no headers. Mounted in the endpoint, so it covers every route, the
  fallback controller and raised errors alike. A response that names its own
  (`RotationLockCheck`'s 60) keeps it.
  """
  import Plug.Conn

  @seconds "30"

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      if conn.status == 503 and get_resp_header(conn, "retry-after") == [],
        do: put_resp_header(conn, "retry-after", @seconds),
        else: conn
    end)
  end
end
