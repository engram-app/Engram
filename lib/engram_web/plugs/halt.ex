defmodule EngramWeb.Plugs.Halt do
  @moduledoc """
  The one halt-with-JSON idiom shared by every plug that rejects a request:
  set the JSON content type, send the encoded body, halt the pipeline.

  `rate_limited/3` is the one 429 shape for a limiter deny: `retry-after` in
  whole seconds (at least 1) plus a JSON body. Anything else beyond the idiom
  (other headers, assigns for RequestLogger, logging/telemetry) stays at the
  call site —
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

  @doc "429 for a limiter deny: `retry-after` rounded up to whole seconds, min 1."
  @spec rate_limited(Plug.Conn.t(), integer(), term()) :: Plug.Conn.t()
  def rate_limited(conn, retry_after_ms, body \\ %{error: "rate_limited"}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds(retry_after_ms)))
    |> json(429, body)
  end

  @doc false
  @spec retry_after_seconds(integer()) :: pos_integer()
  def retry_after_seconds(ms) when is_integer(ms) and ms > 0, do: div(ms + 999, 1000)
  def retry_after_seconds(_ms), do: 1
end
