defmodule EngramWeb.Plugs.SettleUnreadBody do
  @moduledoc """
  Wraps the router so a request body nobody read is drained after the
  response, wherever the refusal came from (Auth 401, rate limiter 429,
  VaultPlug 404, a controller 415, ...).

  Plug.Parsers leaves `application/octet-stream` unread (`pass: ["*/*"]`), so
  every refusal on the raw attachment upload answers with the body still on
  the socket. A bare Bandit (self-host, no buffering proxy) drains at most
  8 MB after responding and closes on more, so a client could see a reset
  instead of the status. Draining here, bounded by the endpoint body ceiling,
  covers the whole pipeline once instead of at every refusal site.

  It runs AFTER the router returns because a before_send hook cannot do it:
  Plug.Conn.send_resp/1 hands the adapter the pre-callback state, so a read
  inside the hook is lost and Bandit would re-read a stale socket state.

  Considered and rejected: reading the raw body before auth, as Plug.Parsers
  does for JSON. It would buffer up to the ceiling per unauthenticated request
  and bypass the plan's per-file read cap; draining discards in 1 MB reads.

  A declared length past the ceiling is never drained: the response is marked
  `connection: close` (HTTP/1; illegal in HTTP/2, RFC 9113 8.2.2) before
  routing, so every refusal on it closes instead.
  """

  @behaviour Plug

  import Plug.Conn

  @read 1_048_576

  @impl true
  def init(router), do: {router, router.init([])}

  @impl true
  def call(conn, {router, router_opts}) do
    conn
    |> mark_oversized()
    |> router.call(router_opts)
    |> settle()
  end

  @doc """
  Marks the connection to close after this response, and skips the drain. For
  a body that will not be read (stalled, over the ceiling, read error).
  """
  def close_after(conn) do
    conn = put_private(conn, :engram_skip_drain, true)

    if get_http_protocol(conn) == :"HTTP/2",
      do: conn,
      else: put_resp_header(conn, "connection", "close")
  end

  @doc "Drains an unread body once the response is sent."
  def settle(%Plug.Conn{state: :sent, private: %{engram_skip_drain: true}} = conn), do: conn

  def settle(%Plug.Conn{state: :sent} = conn),
    do: drain(conn, EngramWeb.Endpoint.max_body_bytes())

  def settle(conn), do: conn

  defp mark_oversized(conn) do
    with [value | _] <- get_req_header(conn, "content-length"),
         {n, ""} <- Integer.parse(value),
         true <- n > EngramWeb.Endpoint.max_body_bytes() do
      close_after(conn)
    else
      _ -> conn
    end
  end

  defp drain(conn, budget) when budget < 0, do: conn

  defp drain(conn, budget) do
    case read_body(conn, length: @read, read_length: @read) do
      {:more, discard, conn} -> drain(conn, budget - byte_size(discard))
      {:ok, _discard, conn} -> conn
      {:error, _reason} -> conn
    end
  end
end
