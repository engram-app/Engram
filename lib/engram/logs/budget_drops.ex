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

  Requests refused at the front of the pipeline
  (`EngramWeb.Plugs.ClientLogsThrottle`) have no user yet. The controller
  `remember/2`s which user a spent token belongs to when it first refuses it,
  and `add_by_key/3` credits the later refusals to that user. A node that
  never saw the first refusal (the mark reached it by cluster broadcast) has
  no claim, so its refusals reach the metric but not this line.

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

  @doc "Remember which user the spent-token `key` belongs to, for `add_by_key/3`."
  @spec remember(String.t(), String.t()) :: :ok
  def remember(key, user_id) do
    _ = :ets.insert(@table, {{:claim, key}, user_id, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "`add/3` for a front-of-pipeline refusal: the user is whoever `remember/2`d `key`."
  @spec add_by_key(String.t(), String.t(), pos_integer()) :: :ok
  def add_by_key(key, device, lines) do
    case :ets.lookup(@table, {:claim, key}) do
      [{_, user_id, _}] -> add(user_id, device, lines)
      [] -> :ok
    end
  end

  @doc "Log one warning per device with drops since the last flush, and reset them."
  @spec flush() :: :ok
  def flush do
    drop_stale_claims()

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

  # A claim is only read while its token's mark lives: one budget window.
  defp drop_stale_claims do
    cutoff = System.monotonic_time(:millisecond) - EngramWeb.Plugs.ClientLogsThrottle.window_ms()
    :ets.select_delete(@table, [{{{:claim, :_}, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
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
