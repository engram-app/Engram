defmodule EngramWeb.Plugs.RetryAfter do
  @moduledoc """
  Gives every 503 a `Retry-After` when the response set none: a 503 is
  transient by definition, and the error renderer (a raised
  `Plug.Exception` with status 503, such as `Engram.Crypto.DekUnavailableError`)
  sets no headers. Mounted in the endpoint, so it covers every route, the
  fallback controller and raised errors alike. A response that names its own
  (`RotationLockCheck`'s 60) keeps it.

  A 429 with none gets a short one: limiters set their own, so this only fires
  for a raised 429 (`Engram.Vaults.SeqGate.Busy`), whose queue drains in
  milliseconds once it moves. The plugin waits `retry-after` on a 429 instead
  of counting the attempt toward parking the write.
  """
  import Plug.Conn

  @seconds "30"
  @busy_seconds "2"

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      case {conn.status, get_resp_header(conn, "retry-after")} do
        {503, []} -> put_resp_header(conn, "retry-after", @seconds)
        {429, []} -> put_resp_header(conn, "retry-after", @busy_seconds)
        _ -> conn
      end
    end)
  end
end
