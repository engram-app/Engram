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

  Only HTTP/1 is drained. Bandit HTTP/2 resets an unread stream with
  RST_STREAM(NO_ERROR) right after the response, which is the correct outcome
  and costs the client nothing (the connection stays up). Draining it instead
  let a client trickling a byte every few seconds hold the stream for weeks,
  since every read made progress and the 15 s read timeout never fired.
  """

  @behaviour Plug

  import Plug.Conn

  @read 1_048_576

  # Wall-clock cap on the drain. 30 s carries the 11 MB ceiling at ~3 Mbit/s,
  # a slow but honest uplink. Past it Bandit's own cleanup (8 MB, 15 s per read)
  # takes over exactly as it would without this plug, so a slow client can hold
  # the connection at most 30 s longer than bare Bandit allows. The check runs
  # between reads; a single 1 MB read is bounded only by Bandit's read timeout.
  @drain_ms 30_000

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

  @doc """
  Drains an unread HTTP/1 body once the response is sent, for at most
  `drain_ms` of wall-clock time.
  """
  def settle(conn, drain_ms \\ @drain_ms)

  def settle(%Plug.Conn{state: :sent, private: %{engram_skip_drain: true}} = conn, _drain_ms),
    do: conn

  def settle(%Plug.Conn{state: :sent} = conn, drain_ms) do
    if get_http_protocol(conn) in [:"HTTP/1.1", :"HTTP/1.0"] do
      deadline = System.monotonic_time(:millisecond) + drain_ms
      drain(conn, EngramWeb.Endpoint.max_body_bytes(), deadline)
    else
      conn
    end
  end

  def settle(conn, _drain_ms), do: conn

  defp mark_oversized(conn) do
    with [value | _] <- get_req_header(conn, "content-length"),
         {n, ""} <- Integer.parse(value),
         true <- n > EngramWeb.Endpoint.max_body_bytes() do
      close_after(conn)
    else
      _ -> conn
    end
  end

  defp drain(conn, budget, _deadline) when budget < 0, do: conn

  defp drain(conn, budget, deadline) do
    case read_body(conn, length: @read, read_length: @read) do
      {:more, discard, conn} ->
        if System.monotonic_time(:millisecond) < deadline,
          do: drain(conn, budget - byte_size(discard), deadline),
          else: conn

      {:ok, _discard, conn} ->
        conn

      {:error, _reason} ->
        conn
    end
  end
end
