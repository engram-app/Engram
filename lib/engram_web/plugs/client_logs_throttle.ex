defmodule EngramWeb.Plugs.ClientLogsThrottle do
  @moduledoc """
  Front-of-pipeline refusal for `POST /api/logs`. Once `LogsController` has
  refused a caller over its line budget it calls `mark_spent/1`; until that
  budget window ends, this plug answers the caller's next requests with the
  same throttled 200 BEFORE `PreAuthRateLimit`, `Auth`, the tenant
  transaction or any other plug runs. One ETS read (`RateLimiter.peek/3`), no
  DB query.

  Why: a looping plugin kept posting at ~4.7 req/s after its budget was
  spent, and every refused request still paid for token verification, the
  onboarding and subscription reads and a tenant transaction.

  ## Key

  `client_logs_spent:<sha256 of the bearer token>:<X-Device-Id or "user">`.

    * The token hash is what keeps one client from throttling another: the
      marker is written only after `Auth` accepted that exact token, and only
      a request carrying the same token can read it. A device id alone would
      not do: it is client-chosen, so anyone could send a throttled device's
      id (or collide on the `"user"` fallback). Hashed so the raw token never
      sits in the limiter table or crosses the cluster broadcast.
    * The device id matches the controller's per-device budget, so two
      devices sharing one API key keep separate refusals.
    * No IP: the token already isolates callers, and a roaming client would
      only miss the marker and take the full path once more.

  A request without a bearer token (a browser session) is never marked and
  always takes the full path, where the controller's own budget check still
  refuses it.

  The marker is a hit in a bucket of the budget's own window, so it expires
  exactly when the budget resets (both are Hammer's epoch-aligned fixed
  windows). Accepted: a token revoked inside the window still gets the
  throttled 200 rather than a 401 until the window ends; the answer writes
  and reveals nothing.
  """

  import Plug.Conn

  alias EngramWeb.OriginDevice
  alias EngramWeb.RateLimiter

  # The per-device line budget's window (`LogsController`).
  @window_ms :timer.minutes(10)

  @doc "The client-log line budget window, in ms."
  def window_ms, do: @window_ms

  def init(opts), do: opts

  def call(conn, _opts) do
    case key(conn) do
      nil -> conn
      key -> if RateLimiter.peek(key, @window_ms, 1) == 0, do: halt(throttled(conn)), else: conn
    end
  end

  @doc "Remember that this caller's budget is spent for the rest of the window."
  @spec mark_spent(Plug.Conn.t()) :: :ok
  def mark_spent(conn) do
    _ = if key = key(conn), do: RateLimiter.hit(key, @window_ms, 1, :client_logs)
    :ok
  end

  @doc """
  The over-budget answer: still a 200 (an old plugin re-buffers a failed
  batch, so a 429 is a retry storm), but saying so and for how long.
  """
  @spec throttled(Plug.Conn.t()) :: Plug.Conn.t()
  def throttled(conn) do
    Phoenix.Controller.json(conn, %{
      ok: true,
      count: 0,
      throttled: true,
      retry_after_ms: RateLimiter.window_reset_ms(@window_ms)
    })
  end

  defp key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        hash = :sha256 |> :crypto.hash(token) |> Base.url_encode64(padding: false)
        "client_logs_spent:#{hash}:#{OriginDevice.from_conn(conn) || "user"}"

      _ ->
        nil
    end
  end
end
