defmodule Engram.Logs.BudgetDrops do
  @moduledoc """
  The `client log budget exceeded` warning, at most once per device per
  window. `POST /api/logs` refusals over the per-device line budget only add
  their line count here; every 10 minutes (and on shutdown) each device with
  pending drops becomes ONE warning carrying the sum, with the user and
  device ids HMAC-hashed.

  It used to be one warning per refused request: a looping plugin at ~4.7
  req/s wrote ~16k of them an hour, and with no owner ids on the line nobody
  could say whose device it was.

  Per node, in ETS, as `Engram.Analytics.Folds`: a hard crash loses up to one
  window of counts. The exact totals are on
  `[:engram, :client_logs, :dropped]`; this line is for finding the device.
  The timer is off in test (`:client_log_budget_drops_flush_ms` nil); tests
  call `flush/0`.
  """
  use GenServer

  alias Engram.Crypto.HMAC
  alias Engram.Logger.Metadata

  require Logger

  @table :engram_client_log_budget_drops

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Count `lines` refused for `user_id`'s `device` (the raw X-Device-Id, or a fallback)."
  @spec add(String.t(), String.t(), pos_integer()) :: :ok
  def add(user_id, device, lines) do
    _ = :ets.update_counter(@table, {user_id, device}, lines, {{user_id, device}, 0})
    :ok
  end

  @doc "Log one warning per device with drops since the last flush, and reset them."
  @spec flush() :: :ok
  def flush do
    for key <- :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}]),
        [{{user_id, device}, dropped}] <- [:ets.take(@table, key)],
        dropped > 0 do
      Logger.warning(
        "client log budget exceeded: dropped #{dropped} lines",
        Metadata.with_category(:warning, :client,
          dropped: dropped,
          user_id: HMAC.hash_user_id(user_id),
          device_id: HMAC.hash_id(device)
        )
      )
    end

    :ok
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    _ = :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush()
    schedule()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    flush()
    :ok
  end

  defp schedule do
    _ =
      if ms = Application.get_env(:engram, :client_log_budget_drops_flush_ms, :timer.minutes(10)) do
        Process.send_after(self(), :flush, ms)
      end

    :ok
  end
end
