defmodule EngramWeb.Plugs.RetryAfter do
  @moduledoc """
  Gives every 503 a `Retry-After` when the response set none: a 503 is
  transient by definition, and the error renderer (a raised
  `Plug.Exception` with status 503, such as `Engram.Crypto.DekUnavailableError`)
  sets no headers. Mounted in the endpoint, so it covers every route, the
  fallback controller and raised errors alike. A response that names its own
  (`RotationLockCheck`'s 60) keeps it.

  A shed vault write (`Engram.Vaults.SeqGate.BusyError`, rendered as a bare
  429) gets a short one: its queue drains in milliseconds once it moves, and
  the plugin waits `retry-after` on a 429 instead of counting the attempt
  toward parking the write. A request shed by its own DB bound
  (`Engram.Repo.ShedError`) is the same kind of load and gets the same value.
  ONLY those exceptions, identified by the `reason` Phoenix's error renderer
  assigns. Every other 429 keeps exactly what its
  limiter set, including none: a cap-0 refusal deliberately carries no
  `retry-after`, so a client has nothing to loop on.

  The busy value is constant, not jittered: the header is whole seconds, so
  server-side jitter could only pick 2 or 3, and a client reading it exactly
  would still cluster on those ticks. The clients spread their own resends
  instead (web `api/client.ts` adds 0-50%).
  """
  import Plug.Conn

  @seconds "30"
  @busy_seconds "2"

  def init(opts), do: opts

  @doc "Seconds a client should wait before resending a write the vault gate shed."
  def busy_seconds, do: String.to_integer(@busy_seconds)

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      case {conn.status, get_resp_header(conn, "retry-after")} do
        {503, []} ->
          put_resp_header(conn, "retry-after", @seconds)

        {429, []} ->
          if shed?(conn), do: put_resp_header(conn, "retry-after", @busy_seconds), else: conn

        _ ->
          conn
      end
    end)
  end

  # The one 429 retry-after rule: a shed write (gate) or a shed request (DB
  # bound) waits the same constant `busy_seconds/0`; the clients jitter.
  defp shed?(conn),
    do:
      match?(
        %shed{} when shed in [Engram.Vaults.SeqGate.BusyError, Engram.Repo.ShedError],
        conn.assigns[:reason]
      )
end
