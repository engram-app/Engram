defmodule Engram.PromEx.Native do
  @moduledoc """
  PromEx plugin for native (Rust NIF) code. Two halves of the NIF memory
  standard (see `Engram.Native`):

    * `[:engram, :nif, :call, :stop]`, per call: duration and NATIVE peak
      bytes, tagged by `:nif`. The peak is the NIF's analogue of a process's
      heap high-water mark, which no BEAM metric can see.
    * `[:engram, :vm, :native_memory]`, polled: OS RSS against the BEAM's
      own total. `unaccounted` (RSS minus everything the BEAM's allocators
      know about) is the only signal for native memory held OUTSIDE them:
      a third-party NIF on its own allocator (y_ex, lingua) shows up only
      there. Alert on its growth, not its level: shared libraries and code
      already put tens of MB there at boot, and it can even go negative,
      because the BEAM counts allocated memory the OS has not made resident.

  Cardinality contract: `:nif` is a closed set of atoms named in
  `Engram.Native`. Never tag with user, vault or note ids.
  """
  use PromEx.Plugin

  @call_event [:engram, :nif, :call, :stop]
  @memory_event [:engram, :vm, :native_memory]

  @impl true
  def event_metrics(opts) do
    prefix = PromEx.metric_prefix(Keyword.fetch!(opts, :otp_app), :nif)

    Event.build(:engram_nif_event_metrics, [
      distribution(prefix ++ [:call, :duration, :milliseconds],
        event_name: @call_event,
        measurement: :duration,
        description: "NIF call wall time.",
        tags: [:nif],
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 25, 100, 250, 1_000, 5_000]]
      ),
      distribution(prefix ++ [:call, :native_peak, :bytes],
        event_name: @call_event,
        measurement: :native_peak_bytes,
        description: "Peak Rust heap bytes allocated during one NIF call.",
        tags: [:nif],
        reporter_options: [
          buckets: [65_536, 1_048_576, 8_388_608, 33_554_432, 134_217_728, 536_870_912]
        ]
      ),
      sum(prefix ++ [:call, :input, :bytes],
        event_name: @call_event,
        measurement: :input_bytes,
        description: "Bytes handed to NIFs.",
        tags: [:nif]
      )
    ])
  end

  @impl true
  def polling_metrics(opts) do
    prefix = PromEx.metric_prefix(Keyword.fetch!(opts, :otp_app), :native_memory)
    poll_rate = Keyword.get(opts, :native_memory_poll_rate, 15_000)

    Polling.build(
      :engram_native_memory_polling_metrics,
      poll_rate,
      {__MODULE__, :execute_native_memory, []},
      for {key, description} <- [
            rss: "OS resident set size of the BEAM process.",
            erlang_total: "Everything the BEAM's own allocators account for.",
            nif_live: "Live Rust heap bytes of the in-house NIF library.",
            unaccounted: "RSS the BEAM cannot attribute: native memory outside its allocators."
          ] do
        last_value(prefix ++ [key, :bytes],
          event_name: @memory_event,
          measurement: key,
          description: description
        )
      end
    )
  end

  @doc "Polled emitter for `[:engram, :vm, :native_memory]`."
  @spec execute_native_memory() :: :ok
  def execute_native_memory do
    snapshot = Engram.Native.memory_snapshot()
    :telemetry.execute(@memory_event, Map.reject(snapshot, fn {_k, v} -> is_nil(v) end), %{})
  end
end
