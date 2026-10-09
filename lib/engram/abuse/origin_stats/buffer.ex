defmodule Engram.Abuse.OriginStats.Buffer do
  @moduledoc """
  Owns the `OriginStats` counter table and flushes it every 30s and on
  shutdown. A hard crash loses at most one interval of counts (accepted:
  the counters are fair-use telemetry, not billing).

  The timer is off in test (`:origin_stats_flush_ms` nil); tests flush by hand.
  """
  use GenServer

  alias Engram.Abuse.OriginStats

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(OriginStats.table(), [:named_table, :public, write_concurrency: true])
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    OriginStats.flush()
    schedule()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    # Off in test: the sandbox is gone by VM stop, so the flush is only noise.
    if Application.get_env(:engram, :origin_stats_flush_on_terminate, true),
      do: OriginStats.flush()

    :ok
  end

  defp schedule do
    if ms = Application.get_env(:engram, :origin_stats_flush_ms, 30_000) do
      Process.send_after(self(), :flush, ms)
    end
  end
end
