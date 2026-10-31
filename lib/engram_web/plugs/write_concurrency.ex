defmodule EngramWeb.Plugs.WriteConcurrency do
  @moduledoc """
  Bulkhead: caps one user's concurrent write requests (see
  `Engram.Vaults.SeqGate`) so a single client can never occupy more than about
  half a web task's DB pool. Over the cap: 429 + `retry-after`.

  Request-count limiters (`PreAuthRateLimit`, `RequireApiRpsBudget`) do not bound
  concurrency, so a burst under 600/min still starved the pool. Reads and
  `/api/mcp` (POST carries searches) are exempt. The slot is released when the
  response is sent; a crashed request process frees it via the gate's monitor.
  """
  import Plug.Conn

  alias Engram.Vaults.SeqGate
  alias EngramWeb.Plugs.Halt

  @writes ~w(POST PUT PATCH DELETE)
  @retry_after_ms 1_000

  def init(opts), do: opts

  def call(%Plug.Conn{method: m, request_path: path, assigns: %{current_user: user}} = conn, _)
      when m in @writes do
    if String.starts_with?(path, "/api/mcp") do
      conn
    else
      case SeqGate.enter_user(user.id) do
        {:ok, ref} -> register_before_send(conn, fn c -> SeqGate.leave_user(ref) && c end)
        :deny -> deny(conn)
      end
    end
  end

  def call(conn, _), do: conn

  defp deny(conn) do
    :telemetry.execute(
      [:engram, :rate_limiter, :hit],
      %{count: 1},
      %{purpose: :write_inflight, result: :deny}
    )

    Halt.rate_limited(conn, @retry_after_ms, %{error: "too_many_concurrent_writes"})
  end
end
