defmodule Engram.Analytics.EventLog.Buffer do
  @moduledoc """
  Owns the `Engram.Analytics.EventLog` buffer table and flushes it every 5s,
  when it fills (`EventLog` sends `:flush`), and on shutdown. Modeled on
  `Engram.Abuse.OriginStats.Buffer`.

  The timer is off in test (`:analytics_event_log_flush_ms` nil); tests call
  `EventLog.flush/0`.
  """
  use GenServer

  alias Engram.Analytics.EventLog

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    _ = :ets.new(EventLog.table(), [:named_table, :public, :set, write_concurrency: true])
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    EventLog.flush()
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    EventLog.flush()
    schedule()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    # Off in test: the sandbox is gone by VM stop, so the flush is only noise.
    if Application.get_env(:engram, :analytics_event_log_flush_on_terminate, true),
      do: EventLog.flush()

    :ok
  end

  defp schedule do
    _ =
      if ms = Application.get_env(:engram, :analytics_event_log_flush_ms, 5_000) do
        Process.send_after(self(), :tick, ms)
      end

    :ok
  end
end
