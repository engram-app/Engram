defmodule Engram.PromEx.Qdrant do
  @moduledoc """
  PromEx plugin for the Qdrant HTTP client (`Engram.Vector.Qdrant`).

  Subscribes to telemetry events emitted by the Qdrant adapter:

    * `[:engram, :qdrant, :request, :start]`
    * `[:engram, :qdrant, :request, :stop]` — `%{duration: native}`,
      metadata `%{op: atom, status: :ok | :error}` where `op` is one of
      `:search | :upsert | :update_vectors | :delete | :scroll | :ensure_collection | :create_payload_index | :set_payload | :collection_info | :collection_memory | :update_collection`.

  Metrics:

    * `engram_prom_ex_qdrant_request_duration_milliseconds` — distribution
      tagged by `:op` + `:status`. Buckets tuned to Qdrant local + Cloud
      latency (~5-100ms typical, fall-back up to 5s).
    * `engram_prom_ex_qdrant_request_total` — counter for ops/sec by op +
      status (error-rate derivable).

  Polled every 60s by ONE process in the cluster (a `:global` name), from
  `GET /collections/{name}` and `GET /collections/{name}/memory` (Qdrant
  1.18+; a 404 on older servers just skips the memory gauges):

    * `engram_prom_ex_qdrant_collection_green` (1/0),
      `engram_prom_ex_qdrant_optimizer_ok` (1/0),
      `engram_prom_ex_qdrant_points`, `engram_prom_ex_qdrant_segments`
    * `engram_prom_ex_qdrant_disk_bytes`
    * `engram_prom_ex_qdrant_ram_bytes{component}`: non-evictable RAM for
      `total`, `dense` (storage + HNSW), `sparse_index`, `payload_index`,
      `payload`, `quantized`, `id_tracker`.

  Only the polling node publishes these; aggregate with `max`, never `sum`.

  Cardinality contract: only `:op` (closed enum) + `:status`, and the closed
  `:component` enum above. NEVER add user_id, vault_id, point ids, or
  collection names.
  """

  use PromEx.Plugin

  alias Engram.Logger.Metadata
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  require Logger

  @collection_event [:engram, :qdrant, :collection]
  @disk_event [:engram, :qdrant, :disk]
  @ram_event [:engram, :qdrant, :memory]
  @poller_name {__MODULE__, :collection_poller}

  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    prefix = PromEx.metric_prefix(otp_app, :qdrant)
    poll_rate = Keyword.get(opts, :qdrant_poll_rate, :timer.seconds(60))

    Polling.build(
      :engram_qdrant_collection_polling_metrics,
      poll_rate,
      {__MODULE__, :execute_collection_metrics, []},
      [
        last_value(prefix ++ [:collection, :green],
          event_name: @collection_event,
          measurement: :green,
          description: "1 when the Qdrant collection status is green."
        ),
        last_value(prefix ++ [:optimizer, :ok],
          event_name: @collection_event,
          measurement: :optimizer_ok,
          description: "1 when the Qdrant optimizer reports ok (0 = optimizer error)."
        ),
        last_value(prefix ++ [:points],
          event_name: @collection_event,
          measurement: :points,
          description: "Approximate points in the Qdrant collection."
        ),
        last_value(prefix ++ [:segments],
          event_name: @collection_event,
          measurement: :segments,
          description: "Segments in the Qdrant collection."
        ),
        last_value(prefix ++ [:disk, :bytes],
          event_name: @disk_event,
          measurement: :bytes,
          description: "Bytes the Qdrant collection holds on disk."
        ),
        last_value(prefix ++ [:ram, :bytes],
          event_name: @ram_event,
          measurement: :ram_bytes,
          tags: [:component],
          description: "Non-evictable RAM the Qdrant collection holds, by component."
        )
      ]
    )
  end

  @doc false
  # telemetry_poller PERMANENTLY drops a measurement that raises, so every
  # failure here is caught and the tick skipped; the next tick retries.
  @spec execute_collection_metrics() :: :ok
  def execute_collection_metrics do
    if ServiceConfig.get(:qdrant_collection_metrics, true) and poller?() do
      poll(Qdrant.collection_name())
    end

    :ok
  rescue
    e -> Logger.warning("qdrant collection poll skipped: #{inspect(e.__struct__)}")
  catch
    :exit, _ -> Logger.warning("qdrant collection poll skipped: exit")
  end

  # One poller per cluster. The name is released when its process dies, and
  # the next tick on another node takes it. `random_notify_name` resolves a
  # netsplit by unregistering, never by killing the PromEx poller.
  defp poller? do
    case :global.whereis_name(@poller_name) do
      pid when pid == self() ->
        true

      :undefined ->
        :global.register_name(@poller_name, self(), &:global.random_notify_name/3) == :yes

      _other ->
        false
    end
  end

  defp poll(col) do
    case Qdrant.collection_info(col, :search) do
      {:ok, info} ->
        :telemetry.execute(@collection_event, collection_measurements(info), %{})
        poll_memory(col)

      {:error, reason} ->
        Logger.warning("qdrant collection poll skipped: #{Metadata.safe_reason(reason)}")
    end
  end

  defp collection_measurements(info) do
    %{
      green: if(info["status"] == "green", do: 1, else: 0),
      optimizer_ok: if(info["optimizer_status"] == "ok", do: 1, else: 0),
      points: info["points_count"] || 0,
      segments: info["segments_count"] || 0
    }
  end

  defp poll_memory(col) do
    case Qdrant.collection_memory(col) do
      {:ok, report} ->
        :telemetry.execute(
          @disk_event,
          %{bytes: get_in(report, ["total", "disk_bytes"]) || 0},
          %{}
        )

        for {component, bytes} <- ram_by_component(report) do
          :telemetry.execute(@ram_event, %{ram_bytes: bytes}, %{component: component})
        end

      {:error, :unsupported} ->
        :ok

      {:error, reason} ->
        Logger.warning("qdrant memory poll skipped: #{Metadata.safe_reason(reason)}")
    end
  end

  # Shape: lib/collection/src/common/memory_reporter.rs (CollectionMemoryReport).
  defp ram_by_component(report) do
    vectors = report["vectors"] || []

    %{
      "total" => ram(report["total"]),
      "dense" => ram_sum(vectors, &(ram(&1["storage"]) + ram(&1["index"]))),
      "quantized" => ram_sum(vectors, &ram(&1["quantized"])),
      "sparse_index" => ram_sum(report["sparse_vectors"] || [], &ram(&1["index"])),
      "payload_index" => ram_sum(report["payload_index"] || [], &ram(&1["usage"])),
      "payload" => ram(report["payload"]),
      "id_tracker" => ram(get_in(report, ["other", "id_tracker"]))
    }
  end

  defp ram(%{"ram_bytes" => b}) when is_integer(b), do: b
  defp ram(_), do: 0

  defp ram_sum(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

  @stop_event [:engram, :qdrant, :request, :stop]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :qdrant)

    Event.build(
      :engram_qdrant_event_metrics,
      [
        distribution(
          metric_prefix ++ [:request, :duration, :milliseconds],
          event_name: @stop_event,
          measurement: :duration,
          description: "Qdrant HTTP request latency by operation.",
          reporter_options: [
            buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]
          ],
          tags: [:op, :status],
          unit: {:native, :millisecond}
        ),
        counter(
          metric_prefix ++ [:request, :total],
          event_name: @stop_event,
          description: "Qdrant requests by operation + status.",
          tags: [:op, :status]
        )
      ]
    )
  end
end
