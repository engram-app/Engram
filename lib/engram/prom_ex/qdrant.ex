defmodule Engram.PromEx.Qdrant do
  @moduledoc """
  PromEx plugin for the Qdrant HTTP client (`Engram.Vector.Qdrant`).

  Subscribes to telemetry events emitted by the Qdrant adapter:

    * `[:engram, :qdrant, :request, :start]`
    * `[:engram, :qdrant, :request, :stop]` — `%{duration: native}`,
      metadata `%{op: atom, status: :ok | :error}` where `op` is one of
      `:search | :upsert | :update_vectors | :delete | :scroll | :ensure_collection | :create_payload_index | :set_payload | :collection_info | :collection_memory | :update_collection | :quotas | :update_quotas`.

  Metrics:

    * `engram_prom_ex_qdrant_request_duration_milliseconds` — distribution
      tagged by `:op` + `:status`. Buckets tuned to Qdrant local + Cloud
      latency (~5-100ms typical, fall-back up to 5s).
    * `engram_prom_ex_qdrant_request_total` — counter for ops/sec by op +
      status (error-rate derivable).

  Polled every 60s on EVERY node. Each tick makes 4 GETs per node:
  `/collections/{name}`, `/collections/{name}/memory` (Qdrant 1.18+; a 404 on
  older servers skips the memory gauges), `/sys_metrics` and `/metrics` (only
  with `QDRANT_MEMORY_LIMIT_BYTES`). `/memory` is fetched once and shared by
  the gauges and the strict limits; `GET /` (version) is node-cached for 10m.
  Three stages (health, memory, pressure + reconcile) fail independently, so
  a pressure read that raises cannot skip the health gauges.

    * `engram_prom_ex_qdrant_collection_green` (1/0),
      `engram_prom_ex_qdrant_optimizer_ok` (1/0),
      `engram_prom_ex_qdrant_points`, `engram_prom_ex_qdrant_segments`
    * `engram_prom_ex_qdrant_last_poll_timestamp_seconds`: unix time of this
      node's last successful `GET /collections/{name}`, set with the health
      gauges. A failed GET leaves every gauge at its old value (PromEx
      `last_value`), so alerts MUST drop a node whose timestamp is older than
      a few ticks, and alert when no node is fresh.
    * `engram_prom_ex_qdrant_disk_bytes`
    * `engram_prom_ex_qdrant_ram_bytes{component}`: non-evictable RAM for
      `total`, `dense` (storage + HNSW), `sparse_index`, `payload_index`,
      `payload`, `quantized`, `id_tracker`.

    * `engram_prom_ex_qdrant_strict_limit_percent{kind="disk"|"heap"}`: the
      limit Qdrant ENFORCES, read from the collection's `strict_mode_config`
      and, on Qdrant 1.19+, the node-wide `GET /quotas` (one more GET per
      tick; the lower limit wins, `QdrantLayout.applied_limits/3`), so every
      node reports the same value whatever its own reads computed. Absent for
      a guard nothing enforces (1.19+ disk without enabled quotas) or before
      strict mode / quotas are set.
    * `engram_prom_ex_qdrant_reserve_bytes{kind}`: the headroom the desired
      limits keep (`QdrantLayout.strict_limits/2`, computed on each node).
      Only ONE process in the cluster (a `:global` name) PATCHes the desired
      limits, and only when they differ from the applied ones.
    * `engram_prom_ex_qdrant_pressure_percent{kind="disk"|"heap"}`: what the
      EmbedNote preflight reads (`Qdrant.pressure/0`); unknown kinds are absent.

  Every node publishes the same cluster-wide values; aggregate across nodes
  (`min` for health, so any fresh node seeing a fault fires), never `sum`.

  Counter `engram_prom_ex_qdrant_backpressure_total{reason="preflight"|"refused"}`:
  embed jobs snoozed because Qdrant was near (preflight) or at (strict-mode
  refusal) its write limits.

  Cardinality contract: only `:op` (closed enum) + `:status`, and the closed
  `:component` enum above. NEVER add user_id, vault_id, point ids, or
  collection names.
  """

  use PromEx.Plugin

  alias Engram.Logger.Metadata
  alias Engram.PromEx.Buckets
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant
  alias Engram.Vector.QdrantLayout

  require Logger

  @collection_event [:engram, :qdrant, :collection]
  @disk_event [:engram, :qdrant, :disk]
  @ram_event [:engram, :qdrant, :memory]
  @pressure_event [:engram, :qdrant, :pressure]
  @limit_event [:engram, :qdrant, :strict_limit]
  @breaker_event [:engram, :qdrant, :points_breaker]
  @reserve_event [:engram, :qdrant, :reserve]
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
        last_value(prefix ++ [:last_poll, :timestamp, :seconds],
          event_name: @collection_event,
          measurement: :polled_at,
          description:
            "Unix time of this node's last successful Qdrant collection poll (staleness filter)."
        ),
        last_value(prefix ++ [:points],
          event_name: @collection_event,
          measurement: :points,
          description: "Approximate points in the Qdrant collection."
        ),
        last_value(prefix ++ [:max_points],
          event_name: @breaker_event,
          measurement: :max_points,
          description:
            "The strict-mode max_points_count Qdrant applies to the collection (absent when unset)."
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
        ),
        last_value(prefix ++ [:strict_limit, :percent],
          event_name: @limit_event,
          measurement: :percent,
          tags: [:kind],
          description:
            "Strict-mode write-refusal limit Qdrant applies to the collection (its strict_mode_config)."
        ),
        last_value(prefix ++ [:reserve, :bytes],
          event_name: @reserve_event,
          measurement: :bytes,
          tags: [:kind],
          description:
            "Headroom kept free below the strict-mode limit (absent when the limit is the static fallback)."
        ),
        last_value(prefix ++ [:pressure, :percent],
          event_name: @pressure_event,
          measurement: :percent,
          tags: [:kind],
          description:
            "Qdrant fullness the embed preflight reads: disk (storage volume) or heap (resident vs QDRANT_MEMORY_LIMIT_BYTES)."
        )
      ]
    )
  end

  @doc false
  # telemetry_poller PERMANENTLY drops a measurement that raises, so every
  # failure here is caught and the stage skipped; the next tick retries.
  @spec execute_collection_metrics() :: :ok
  def execute_collection_metrics do
    if ServiceConfig.get(:qdrant_collection_metrics, true) do
      col = Qdrant.collection_name()
      # nil version is already a valid "unknown"; a skipped memory fetch reads
      # as the same error shape collection_memory returns on failure.
      version = stage("version", &Qdrant.cached_server_version/0)
      memory = stage("memory", fn -> Qdrant.collection_memory(col) end) || {:error, :skipped}
      info = stage("collection", fn -> poll(col, version) end)
      stage("memory", fn -> poll_memory(memory) end)

      stage("pressure", fn ->
        reading = poll_pressure(memory)

        if is_map(info) and poller?(),
          do: Qdrant.reconcile_strict_mode(col, info, reading.limits, version)
      end)
    end

    :ok
  rescue
    e ->
      _ = skipped("collection", inspect(e.__struct__))
      :ok
  catch
    kind, _ when kind in [:exit, :throw] ->
      _ = skipped("collection", Atom.to_string(kind))
      :ok
  end

  # One stage's raise/exit/throw skips only that stage (returns nil).
  defp stage(name, fun) do
    fun.()
  rescue
    e -> skipped(name, inspect(e.__struct__))
  catch
    kind, _ when kind in [:exit, :throw] -> skipped(name, Atom.to_string(kind))
  end

  defp skipped(name, why) do
    Logger.warning("qdrant #{name} poll skipped: #{why}")
    nil
  end

  # One strict-mode reconciler per cluster. The name is released when its process dies, and
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

  # The health gauges, the last-poll timestamp and the applied strict limits,
  # all from one `GET /collections/{name}`. Returns the info, or nil.
  defp poll(col, version) do
    case Qdrant.collection_info(col, :search) do
      {:ok, info} ->
        :telemetry.execute(@collection_event, collection_measurements(info), %{})

        case get_in(info, ["config", "strict_mode_config", "max_points_count"]) do
          max when is_integer(max) -> :telemetry.execute(@breaker_event, %{max_points: max}, %{})
          _ -> :ok
        end

        limits = QdrantLayout.applied_limits(info["config"], version, poll_quotas(version))

        for {kind, percent} <- limits do
          :telemetry.execute(@limit_event, %{percent: percent}, %{kind: Atom.to_string(kind)})
        end

        info

      {:error, reason} ->
        skipped("collection", Metadata.safe_reason(reason))
    end
  end

  # Qdrant 1.19+: the node-wide quota config (nil before 1.19 or unreadable).
  defp poll_quotas(version) do
    if QdrantLayout.quota_kinds(version) != [] do
      case Qdrant.quotas() do
        {:ok, %{"config" => config}} -> config
        {:ok, _} -> nil
        {:error, reason} -> skipped("quotas", Metadata.safe_reason(reason))
      end
    end
  end

  # An unknown kind publishes nothing (absent, not a misleading 0).
  defp poll_pressure(memory) do
    reading = Qdrant.read_pressure(memory)

    for kind <- [:disk, :heap] do
      tags = %{kind: Atom.to_string(kind)}
      reserve = reading.limits[kind].reserve

      if is_integer(reading[kind]),
        do: :telemetry.execute(@pressure_event, %{percent: reading[kind]}, tags)

      if is_integer(reserve), do: :telemetry.execute(@reserve_event, %{bytes: reserve}, tags)
    end

    reading
  end

  defp collection_measurements(info) do
    %{
      green: if(info["status"] == "green", do: 1, else: 0),
      optimizer_ok: if(info["optimizer_status"] == "ok", do: 1, else: 0),
      points: info["points_count"] || 0,
      segments: info["segments_count"] || 0,
      polled_at: System.os_time(:second)
    }
  end

  defp poll_memory(memory) do
    case memory do
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
          reporter_options: Buckets.opts(Engram.PromEx.Qdrant.RequestDurationBuckets),
          tags: [:op, :status],
          unit: {:native, :millisecond}
        ),
        counter(
          metric_prefix ++ [:request, :total],
          event_name: @stop_event,
          description: "Qdrant requests by operation + status.",
          tags: [:op, :status]
        ),
        counter(
          metric_prefix ++ [:backpressure, :total],
          event_name: [:engram, :qdrant, :backpressure],
          description:
            "Embed jobs snoozed for Qdrant pressure: preflight (before Voyage) or refused (strict mode).",
          tags: [:reason]
        ),
        counter(
          metric_prefix ++ [:strict_shape_refusal, :total],
          event_name: [:engram, :qdrant, :strict_shape_refusal],
          description:
            "Writes Qdrant strict mode refused for their shape (limit, condition or filter size): a code bug."
        ),
        counter(
          metric_prefix ++ [:wait_timeout, :total],
          event_name: [:engram, :qdrant, :wait_timeout],
          description:
            "Writes whose wait=true outlived the server timeout: queued, not yet applied, so not stamped."
        )
      ]
    )
  end
end

defmodule Engram.PromEx.Qdrant.RequestDurationBuckets do
  @moduledoc false
  use Engram.PromEx.Buckets, [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]
end
