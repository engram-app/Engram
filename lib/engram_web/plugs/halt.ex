defmodule EngramWeb.Plugs.Halt do
  @moduledoc """
  The one halt-with-JSON idiom shared by every plug that rejects a request:
  set the JSON content type, send the encoded body, halt the pipeline.

  Anything beyond the idiom (extra response headers like `Retry-After`,
  assigns for RequestLogger, logging/telemetry) stays at the call site —
  headers put on the conn before calling `json/3` are preserved by
  `send_resp/3`. `EngramWeb.LimitResponse` intentionally does NOT go
  through here: it owns additional header semantics.
  """

  import Plug.Conn

  @spec json(Plug.Conn.t(), pos_integer(), term()) :: Plug.Conn.t()
  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
