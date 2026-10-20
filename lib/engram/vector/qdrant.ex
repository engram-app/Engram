defmodule Engram.Vector.Qdrant do
  @moduledoc """
  Thin Req-based HTTP wrapper for the Qdrant REST API.
  All operations target a single collection.

  Config:
  - :qdrant_url — base URL (default http://localhost:6333)
  - QDRANT_API_KEY env var — API key for Qdrant Cloud (optional for local)

  Ops kill switches (env, read at boot in every environment; all default on;
  `false`/`0` to turn off, then restart):
  - QDRANT_RECONCILE_CONFIG: false = never PATCH the collection config (boot
    reconcile and the 60s poller's strict-mode sync).
  - QDRANT_RECONCILE_ON_DISK: false = skip only the on-disk group.
  - QDRANT_STRICT_MODE: false = the reconcile sets our two strict-mode
    guards (`max_disk_usage_percent`, `max_resident_memory_percent`) to 100;
    `enabled` and every other strict field (Qdrant Cloud's unindexed-filter
    guard) are left as they are.
  - QDRANT_BACKPRESSURE_PREFLIGHT: false = EmbedNote never pauses for pressure.
  """

  alias Engram.Logger.Metadata
  alias Engram.Search.Fusion
  alias Engram.ServiceConfig
  alias Engram.Vector.QdrantLayout

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @default_url "http://localhost:6333"
  @default_collection "obsidian_notes"

  # Payload fields every tenant-scoped op filters on. Qdrant Cloud strict-mode
  # rejects (400) a filter on an un-indexed field, so each must have a keyword
  # index before any upsert/search/delete. `note_id` is not a live filter key
  # today (deletes resolve via `path_hmac`) but is indexed to match the prod
  # collection + future-proof. See #626. `type_hmac` is the OKF frontmatter
  # `type` blind index (spec 2026-07-02). `folder_hmac`/`tags_hmac` are the
  # folder and tag search filters (#1609).
  @payload_index_fields ~w(user_id vault_id note_id path_hmac type_hmac folder_hmac tags_hmac)

  # OKF frontmatter dates are stored plaintext (see build_prepared/6) so
  # Qdrant can range-filter on them; they need an integer payload index
  # rather than keyword.
  @integer_payload_index_fields ~w(fm_timestamp fm_created)

  defp base_url, do: ServiceConfig.get(:qdrant_url, @default_url)
  defp collection, do: ServiceConfig.get(:qdrant_collection, @default_collection)

  @doc "Returns the configured Qdrant collection name (env-var-driven)."
  def collection_name, do: collection()

  defp binary_quantization_enabled?,
    do: ServiceConfig.get(:qdrant_binary_quantization, true)

  # Wrap an HTTP call in a `:telemetry.span` so the PromEx Qdrant plugin
  # (engram-app/engram-infra#340) sees per-op latency + status. `op` is
  # a bounded atom (`:search`, `:upsert`, etc.); status is derived from
  # the result tuple. NEVER include collection name, point ids, or
  # user/vault context — cardinality contract.
  defp instrument(op, fun) when is_atom(op) and is_function(fun, 0) do
    :telemetry.span([:engram, :qdrant, :request], %{op: op}, fn ->
      result = fun.()
      {result, %{op: op, status: qdrant_status(result)}}
    end)
  end

  defp qdrant_status(:ok), do: :ok
  defp qdrant_status({:ok, _}), do: :ok
  defp qdrant_status({:error, _}), do: :error

  # Per-purpose Req options. `:indexing` (default) is patient — 30s timeout +
  # transient retries; callers are Oban workers where an in-call retry is
  # cheaper than burning a job attempt. `:search` backs the synchronous
  # `/api/search` request path and must fail fast: with the indexing opts a
  # Qdrant brownout pins each request up to ~2min (30s x 4 attempts), holding
  # Bandit processes and cascading into pool pressure. Same split the Voyage
  # embedder already has (`request_defaults(:query)` = 5s, no retry).
  @doc false
  def req_opts(purpose \\ :indexing)

  def req_opts(:search) do
    put_api_key(
      # Default 5s fail-fast; overridable per-process so a Bypass test can pin a
      # generous budget and not misread scheduler starvation as a real timeout.
      receive_timeout: ServiceConfig.get(:qdrant_search_timeout, 5_000),
      retry: false,
      max_retries: 0,
      connect_options: [protocols: [:http1]]
    )
  end

  def req_opts(:indexing) do
    {retry, max_retries} =
      case ServiceConfig.get(:qdrant_retry, :transient) do
        false -> {false, 0}
        mode -> {mode, 3}
      end

    put_api_key(
      receive_timeout: 30_000,
      retry: retry,
      max_retries: max_retries,
      retry_log_level: :warning,
      connect_options: [protocols: [:http1]]
    )
  end

  # Point writes wait until APPLIED (`wait=true`): an ack alone let a worker
  # stamp a note indexed while its points were still invisible to search.
  # `timeout` makes Qdrant give up before the client does (`req_opts/1`), so a
  # slow write ends as a server timeout, not a hang-up that leaves it running.
  defp write_opts(body, purpose \\ :indexing) do
    [json: body, params: [wait: true, timeout: server_timeout_s(purpose)]] ++ req_opts(purpose)
  end

  @doc """
  Qdrant-side `timeout` (whole seconds) for a request profile, below that
  profile's client `receive_timeout`. Floored at 1: Qdrant reads 0 as no limit.
  """
  @spec server_timeout_s(:search | :indexing) :: pos_integer()
  def server_timeout_s(:search),
    do: max(div(ServiceConfig.get(:qdrant_search_timeout, 5_000), 1000) - 1, 1)

  # 5s under the 30s indexing `receive_timeout`.
  def server_timeout_s(:indexing), do: 25

  defp put_api_key(base) do
    case ServiceConfig.get(:qdrant_api_key) do
      nil -> base
      key -> Keyword.put(base, :headers, [{"api-key", key}])
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Ensure a collection exists with the given vector dimensions.
  Creates it if missing; no-ops if already present (Qdrant returns 200 either way).

  Also creates the keyword/integer payload indexes every tenant-scoped filter
  depends on (#626, extended for OKF frontmatter fields). On an existing
  collection it creates only the ones its `payload_schema` lacks (#1609), so
  a field added to the list later reaches an already-deployed collection on
  the next boot instead of needing an out-of-band PUT.

  Cost: the `payload_schema` comes from the `collection_info` GET the shape
  check already makes, so a fully indexed collection adds no requests. The
  whole call is memoised per node (#1501), so this runs once per boot.
  """
  def ensure_collection(col \\ nil, dims) do
    col = col || collection()
    key = {base_url(), col, dims}

    # Memoised per node, per {url, collection, dims}. `Indexing.prepare_index/3`
    # calls this for EVERY note, and on an existing collection the work is two
    # network round trips that cannot produce a different answer: a PUT that
    # 409s, then a `collection_info` GET to verify shape. Measured in prod
    # 2026-08-28 — 853 `ensure_collection` and 853 `collection_info` calls
    # against 853 upserts, a 1:1:1 ratio, inside the slowest queue we have
    # (embed averages 738 ms). See #1501.
    #
    # Keyed on the resolved base URL, not just the collection name. That was
    # meant to keep the Bypass suites isolated — "each test's port is its own
    # key" — and it does not, which is why the memo is OFF under `:test` (see
    # `memo_enabled?/0`). A port is only unique while it is held: Bypass
    # releases it on test exit and the OS hands the same number to a later
    # `Bypass.open/0`, whose key then hits a marker the earlier test wrote.
    # `ensure_collection/2` returns `:ok` having issued no request at all, and
    # any test whose only HTTP comes from here dies in `Bypass`'s exit
    # verification with "No HTTP request arrived at Bypass" — far from the
    # cause, in a test that did nothing wrong. Measured directly: 8 requests on
    # a cold memo, 0 after reopening Bypass on the same port.
    #
    # A blanket `forget_collection_memo/0` in shared setup is NOT the fix. It
    # erases the whole namespace, so one async test would clear another's
    # marker mid-run and add unexpected requests — and `indexing_test.exs` and
    # `search_test.exs` both use `Bypass.expect_once`. That trades a
    # missing-request flake for a surplus-request one.
    #
    # ONLY success is memoised. A failure erases the entry so the next caller
    # retries — otherwise one transient Qdrant blip would be cached for the
    # life of the node and every subsequent index would fail against a
    # collection that was fine.
    # Deliberately NOT a read-through helper: that would cache whatever the
    # loader returns, so an error would be written and only then erased. In the
    # window between those two steps a concurrent caller reads the cached error
    # and fails WITHOUT attempting the network — turning one transient Qdrant
    # blip into several. Writing only on success closes that window rather than
    # cleaning up after it. Keys live under `{__MODULE__, key}`, which
    # `forget_collection_memo/0` erases.
    if memo_enabled?() do
      case :persistent_term.get({__MODULE__, key}, :__miss__) do
        :ok ->
          :ok

        :__miss__ ->
          case do_ensure_collection(col, dims) do
            {:ok, :verified} ->
              :persistent_term.put({__MODULE__, key}, :ok)
              :ok

            # Shape and indexes could not be read, so nothing is proven and
            # nothing is cached: the next caller checks again. Caching it would
            # strand a node without the payload indexes strict-mode filtering
            # needs until it restarts, which is the #1609 failure itself.
            {:ok, :unverified} ->
              :ok

            {:error, _} = error ->
              error
          end
      end
    else
      with {:ok, _} <- do_ensure_collection(col, dims), do: :ok
    end
  end

  # Defaults to on, so prod and dev keep #1501's saving; `config/test.exs`
  # turns it off. Switched rather than cleared because a switch cannot be
  # defeated by test ordering — there is no marker to leak in the first place,
  # so no async test can observe or erase another's. The one suite that exists
  # to test the memo turns it back on for itself.
  defp memo_enabled?, do: Application.get_env(:engram, :ensure_collection_memo, true)

  @doc """
  Drop the memoised "this collection is ready" marker for the current node.

  Needed if the collection is dropped or recreated out of band: without this
  the node keeps skipping `ensure_collection` and upserts fail against a
  collection that no longer exists. Not wired to anything automatic — a
  drop/recreate is a deliberate operator action, and this is the deliberate
  counterpart.
  """
  def forget_collection_memo do
    for {{__MODULE__, _} = k, _v} <- :persistent_term.get(), do: :persistent_term.erase(k)

    :ok
  end

  defp do_ensure_collection(col, dims) do
    case create_collection(col, dims) do
      {:ok, :created} ->
        with :ok <- ensure_payload_indexes(col, MapSet.new()), do: reconciled(col)

      {:ok, {:exists, :unknown}} ->
        {:ok, :unverified}

      {:ok, {:exists, indexed}} ->
        with :ok <- ensure_payload_indexes(col, indexed), do: reconciled(col)

      {:error, _} = error ->
        error
    end
  end

  # Storage/safety params are best-effort: a failed reconcile is logged and
  # retried next boot, never a reason to stop indexing. Only the payload
  # indexes above gate `:verified`, because strict mode 400s without them.
  defp reconciled(col) do
    _ = reconcile_config(col)
    {:ok, :verified}
  end

  defp create_collection(col, dims) do
    body =
      dims
      |> QdrantLayout.create_params()
      |> then(fn b ->
        if binary_quantization_enabled?() do
          Map.put(b, "quantization_config", %{"binary" => %{"always_ram" => true}})
        else
          b
        end
      end)

    opts = [json: body] ++ req_opts()

    instrument(:ensure_collection, fn ->
      case Req.put("#{base_url()}/collections/#{col}", opts) do
        {:ok, %{status: status}} when status in [200, 201] -> {:ok, :created}
        {:ok, %{status: 409}} -> existing_collection(col)
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # 409 means the collection already exists. Confirm its shape is compatible
  # and report which fields it already indexes.
  defp existing_collection(col) do
    with {:ok, indexed} <- verify_collection_shape(col), do: {:ok, {:exists, indexed}}
  end

  # Create a payload index for every filtered field the collection lacks.
  # `?wait=true` blocks until each index is ready so the next upsert or search
  # can't race an unbuilt one. Stops at the first failure so a real error
  # surfaces (and is not memoised). Keyword fields are equality/any-match
  # filters; integer fields (the OKF dates) are range filters.
  #
  # Runs on an EXISTING collection too, not just after a fresh create (#1609).
  # Create-only meant a field added to the list later never reached a
  # collection that already existed: prod indexed only the first four, and
  # strict mode 400'd every folder, tag, type and date filter.
  #
  defp ensure_payload_indexes(col, indexed) do
    keyword = Enum.map(@payload_index_fields, &{&1, "keyword"})
    integer = Enum.map(@integer_payload_index_fields, &{&1, "integer"})

    (keyword ++ integer)
    |> Enum.reject(fn {field, _schema} -> MapSet.member?(indexed, field) end)
    |> Enum.reduce_while(:ok, fn {field, schema}, :ok ->
      case create_payload_index(col, field, schema) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp create_payload_index(col, field, schema) do
    # `?wait=true` blocks until the index is built over every existing point,
    # which on a large collection outlasts the default indexing budget. A
    # timeout here fails `ensure_collection` (deliberately not memoised), so
    # every retrying job would re-issue the same build. Give it its own.
    opts =
      [json: %{field_name: field, field_schema: schema}, receive_timeout: 120_000] ++ req_opts()

    instrument(:create_payload_index, fn ->
      case Req.put("#{base_url()}/collections/#{col}/index?wait=true", opts) do
        {:ok, %{status: status}} when status in [200, 201] -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # On an existing collection, confirm it has the named `dense` vector + the
  # `keyword` sparse vector this build requires. A legacy single-unnamed-vector
  # collection would otherwise 400 every upsert/search silently. Pre-launch the
  # collection is recreated (wipeable); this guard catches a stale deploy.
  defp verify_collection_shape(col) do
    case collection_info(col) do
      {:ok, %{"config" => %{"params" => params}} = info} ->
        vectors = params["vectors"] || %{}
        sparse = params["sparse_vectors"] || %{}

        if is_map(vectors) and Map.has_key?(vectors, "dense") and Map.has_key?(sparse, "keyword") do
          {:ok, indexed_fields(info)}
        else
          {:error, {:incompatible_collection_schema, col}}
        end

      _ ->
        # Couldn't read collection info — don't block indexing on a transient
        # read error; the upsert will surface a real failure if shape is wrong.
        {:ok, :unknown}
    end
  end

  defp indexed_fields(info), do: MapSet.new(Map.keys(info["payload_schema"] || %{}))

  @doc """
  Delete a collection. Idempotent: returns `:ok` for both 200 and 404.
  """
  def delete_collection(col) do
    opts = req_opts()

    instrument(:delete_collection, fn ->
      case Req.delete("#{base_url()}/collections/#{col}", opts) do
        {:ok, %{status: status}} when status in [200, 404] -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Get collection info. Returns the raw `result` map from Qdrant
  (includes config, point count, etc.). `purpose` picks the Req opts
  (`:search` = 5s fail-fast, for pollers).
  """
  def collection_info(col, purpose \\ :indexing) do
    instrument(:collection_info, fn -> get_result("/collections/#{col}", purpose) end)
  end

  @doc """
  `GET /collections/{col}/memory` (Qdrant >= 1.18): disk/RAM/page-cache bytes
  per component. Older servers answer 404 -> `{:error, :unsupported}`.
  """
  def collection_memory(col) do
    instrument(:collection_memory, fn ->
      case get_result("/collections/#{col}/memory", :search) do
        {:error, {404, _}} -> {:error, :unsupported}
        other -> other
      end
    end)
  end

  defp get_result(path, purpose) do
    case Req.get(base_url() <> path, req_opts(purpose)) do
      {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Bring the collection's params to `QdrantLayout.desired/1`, PATCHing only
  what differs. Returns the PATCH keys applied (`[]` when already in shape, so
  a normal boot sends no PATCH).

  Four groups, each its own request so one refusal cannot block another, in
  this order:

    1. strict mode (version-gated in `QdrantLayout`), so the disk guard is
       live before anything rebuilds; on Qdrant 1.19+ with
       `QDRANT_MANAGE_QUOTAS=true`, the node-wide `PUT /quotas` too (reported
       as `"quotas"`), since 1.19 moved the disk guard there;
    2. optimizers, always (one optimization thread serialises the rebuild);
    3. on-disk (dense + sparse index), ONLY past `headroom/2`: Qdrant rewrites
       every segment for it, and no optimizer splits an existing segment, so
       the worst case is a rewrite of the whole collection at once.
  """
  def reconcile_config(col \\ nil) do
    if ServiceConfig.get(:qdrant_reconcile_config, true),
      do: do_reconcile_config(col || collection()),
      else: {:ok, []}
  end

  defp strict_mode?, do: ServiceConfig.get(:qdrant_strict_mode, true)

  # Boot only (this runs once per node). A guard the server does not honour
  # is not applied, so say which, rather than imply a write cap that is not
  # there. The app-side preflight still reads disk pressure where it can.
  defp log_missing_guards(nil), do: :ok

  defp log_missing_guards(version) do
    supported = QdrantLayout.guard_kinds(version) ++ managed_quota_kinds(version)

    for {kind, name} <- [disk: "disk", heap: "memory"], kind not in supported do
      Logger.warning("qdrant #{name} write guard unavailable on #{version}")
    end

    :ok
  end

  defp do_reconcile_config(col) do
    with {:ok, info} <- collection_info(col) do
      version = server_version()
      log_missing_guards(version)

      limits = strict_limits(col, volume_stats())

      diff =
        QdrantLayout.diff(
          info["config"] || %{},
          QdrantLayout.desired(version, limits, strict_mode?())
        )

      {strict, rest} = Map.split(diff, ["strict_mode_config"])
      {on_disk, optimizers} = Map.split(rest, QdrantLayout.on_disk_keys())

      # Strict mode first, so the guards are live before anything rebuilds.
      results = [
        {strict, patch_collection(col, strict)},
        quotas_group(reconcile_quotas(version, limits)),
        {optimizers, patch_collection(col, optimizers)},
        on_disk_group(col, on_disk)
      ]

      applied = for {body, :ok} <- results, key <- Map.keys(body), do: key
      if applied != [], do: report_reconciled(applied)

      case for({_body, {:error, _} = e} <- results, do: e) do
        [] -> {:ok, applied}
        [error | _] -> error
      end
    end
    |> tap(&log_reconcile_failure/1)
  end

  @doc """
  Strict-mode limits for `col` now (`QdrantLayout.strict_limits/2`): the
  volume from `/sys_metrics`, the collection's `/memory` disk_bytes and
  `QDRANT_MEMORY_LIMIT_BYTES`. Unknown sizes fall back to
  `QDRANT_STRICT_DISK_PERCENT` / `QDRANT_STRICT_MEMORY_PERCENT` (85).
  `memory`: a `collection_memory/1` result already in hand (the poller
  shares one per tick), or `:fetch`.
  """
  def strict_limits(col, volume, memory \\ :fetch) do
    collection_bytes =
      case if(memory == :fetch, do: collection_memory(col), else: memory) do
        {:ok, %{"total" => %{"disk_bytes" => b}}} when is_integer(b) -> b
        _ -> nil
      end

    QdrantLayout.strict_limits(
      %{
        capacity: volume && volume.capacity,
        collection: collection_bytes,
        memory_limit: ServiceConfig.get(:qdrant_memory_limit_bytes)
      },
      %{
        memory_reserve: ServiceConfig.get(:qdrant_memory_reserve_bytes, 256 * 1024 * 1024),
        static: %{
          disk: ServiceConfig.get(:qdrant_strict_disk_percent, 85),
          heap: ServiceConfig.get(:qdrant_strict_memory_percent, 85)
        }
      }
    )
  end

  @doc """
  Keep the collection's strict-mode limits at `limits` (the poller, every
  tick), so they follow data growth and volume resizes without a deploy. On
  Qdrant 1.19+ with `QDRANT_MANAGE_QUOTAS=true`, `/quotas` is kept at the
  same limits. `version` is the caller's (cached) view, so mid-upgrade nodes
  may disagree; the two paths touch disjoint fields (the strict heap percent
  is the same on both), so they converge instead of fighting.
  PATCHes only when a percent moved (whole points, so >= 1), then logs and
  emits `[:engram, :qdrant, :strict_limits_changed]`.
  """
  def reconcile_strict_mode(col, info, limits, version \\ :fetch) do
    if ServiceConfig.get(:qdrant_reconcile_config, true),
      do: do_reconcile_strict_mode(col, info, limits, version),
      else: :ok
  end

  defp do_reconcile_strict_mode(col, info, limits, version) do
    version = if version == :fetch, do: server_version(), else: version
    strict = reconcile_strict_fields(col, info, limits, version)

    case reconcile_quotas(version, limits) do
      {:error, _} = error -> error
      _ -> strict
    end
  end

  defp reconcile_strict_fields(col, info, limits, version) do
    want =
      version
      |> QdrantLayout.desired(limits, strict_mode?())
      |> Map.take(["strict_mode_config"])

    case QdrantLayout.diff(info["config"] || %{}, want) do
      diff when map_size(diff) == 0 ->
        :ok

      diff ->
        with :ok <- patch_collection(col, diff) do
          strict = diff["strict_mode_config"]

          Logger.info(
            "qdrant strict-mode limits changed: disk=#{inspect(strict["max_disk_usage_percent"])} " <>
              "memory=#{inspect(strict["max_resident_memory_percent"])}"
          )

          :telemetry.execute(
            [:engram, :qdrant, :strict_limits_changed],
            %{count: 1},
            %{disk: strict["max_disk_usage_percent"], heap: strict["max_resident_memory_percent"]}
          )
        end
    end
  end

  @doc """
  `GET /quotas` (Qdrant 1.19+): `{:ok, %{"config" => QuotaConfig, "usage" => ...}}`.
  Node-wide, not per collection.
  """
  def quotas, do: instrument(:quotas, fn -> get_result("/quotas", :search) end)

  # `/quotas` is node-wide: it caps every collection on the server, so it is
  # managed only with QDRANT_MANAGE_QUOTAS=true, on a server that holds this
  # app's collection alone (Qdrant Cloud prod). Shared servers (staging, a
  # self-host Qdrant used by other apps) keep the strict-mode heap guard and
  # the app-side preflight.
  defp managed_quota_kinds(version) do
    if ServiceConfig.get(:qdrant_manage_quotas, false),
      do: QdrantLayout.quota_kinds(version),
      else: []
  end

  # Keep `/quotas` at `limits` (Qdrant 1.19+). PUTs only on drift (PUT
  # replaces the whole config, so the body is all of it), and waits for
  # consensus so the next tick reads back what it wrote.
  # `{:ok, :changed | :unchanged}` or `{:error, _}`.
  defp reconcile_quotas(version, limits) do
    if managed_quota_kinds(version) == [] do
      {:ok, :unchanged}
    else
      want = QdrantLayout.desired_quotas(limits, strict_mode?())

      with {:ok, current} <- quotas() do
        if QdrantLayout.quotas_drift?(current["config"], want),
          do: put_quotas(want),
          else: {:ok, :unchanged}
      end
    end
  end

  defp put_quotas(want) do
    instrument(:update_quotas, fn ->
      case Req.put(base_url() <> "/quotas?wait=true", [json: want] ++ req_opts()) do
        {:ok, %{status: 200}} ->
          disk = want["max_disk_usage_percent"]
          heap = want["max_resident_memory_percent"]
          Logger.info("qdrant quota limits changed: disk=#{disk} memory=#{heap}")

          :telemetry.execute([:engram, :qdrant, :strict_limits_changed], %{count: 1}, %{
            disk: disk,
            heap: heap
          })

          {:ok, :changed}

        {:ok, %{status: status, body: body}} ->
          {:error, {status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp quotas_group({:ok, :changed}), do: {%{"quotas" => true}, :ok}
  defp quotas_group({:ok, :unchanged}), do: {%{}, :ok}
  defp quotas_group(error), do: {%{}, error}

  defp on_disk_group(col, on_disk) do
    body = gate_on_disk(col, on_disk)
    {body, patch_collection(col, body)}
  end

  defp log_reconcile_failure({:error, reason}),
    do: Logger.warning("qdrant config reconcile failed: #{Metadata.safe_reason(reason)}")

  defp log_reconcile_failure(_ok), do: :ok

  @self_host_on_disk_limit 1024 * 1024 * 1024

  # The on-disk group, or `%{}` when the headroom gate defers it. Only
  # evaluated when there is something to apply, so a steady-state boot makes
  # no /memory or /sys_metrics request.
  defp gate_on_disk(_col, on_disk) when map_size(on_disk) == 0, do: on_disk

  defp gate_on_disk(col, on_disk) do
    if ServiceConfig.get(:qdrant_reconcile_on_disk, true) do
      headroom_gate(col, on_disk)
    else
      Logger.info("qdrant_reconcile_deferred source=QDRANT_RECONCILE_ON_DISK")
      %{}
    end
  end

  defp headroom_gate(col, on_disk) do
    collection_bytes =
      case collection_memory(col) do
        {:ok, %{"total" => %{"disk_bytes" => b}}} -> b
        _ -> nil
      end

    {decision, source, free} = headroom(collection_bytes, volume_stats())

    meta = %{decision: decision, source: source}
    measurements = %{free_bytes: free, collection_bytes: collection_bytes}

    Logger.info(
      "qdrant_reconcile_#{if decision == :apply, do: "on_disk_applied", else: "deferred"} " <>
        "source=#{source} free_bytes=#{inspect(free)} collection_bytes=#{inspect(collection_bytes)}"
    )

    :telemetry.execute([:engram, :qdrant, :headroom_gate], measurements, meta)
    if decision == :apply, do: on_disk, else: %{}
  end

  @doc """
  The on-disk headroom decision: `{:apply | :defer, source, free_bytes}`.

  The rewrite needs scratch space for the segment being rebuilt. On a prod
  clone (1.18.2, 447k points, 6 segments, one optimizer thread) it peaked at
  +0.26x the collection's `disk_bytes`. With volume stats (Qdrant Cloud
  `/sys_metrics`) it applies only when free disk is at least 0.5x the
  collection AND the projected peak, used + 0.35x (the measurement plus ~35%
  margin), stays under 80% of capacity, below strict mode's 85% write cap. Without them (self-host) it applies only to a
  collection under 1 GiB. An unknown collection size (no `/memory` before
  Qdrant 1.18) always defers.
  """
  def headroom(nil, volume), do: {:defer, :unknown_size, free_of(volume)}

  def headroom(size, nil) when size < @self_host_on_disk_limit, do: {:apply, :self_host_rule, nil}
  def headroom(_size, nil), do: {:defer, :self_host_rule, nil}

  # Integer form of `free >= 0.5 * size` and `(used + 0.35 * size) / cap < 0.8`.
  def headroom(size, %{used: used, capacity: cap} = volume) do
    free = free_of(volume)
    decision = if 2 * free >= size and 100 * used + 35 * size < 80 * cap, do: :apply, else: :defer
    {decision, :sys_metrics, free}
  end

  defp free_of(%{used: used, capacity: cap}), do: cap - used
  defp free_of(nil), do: nil

  # Qdrant Cloud exposes the volume's kubelet stats on `/sys_metrics`
  # (Prometheus text). Self-host has no such endpoint: nil.
  defp volume_stats do
    case Req.get(base_url() <> "/sys_metrics", [decode_body: false] ++ req_opts(:search)) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> parse_volume_stats(body)
      _ -> nil
    end
  end

  @doc false
  # `%{used:, capacity:}` from the `qdrant-storage-*` PVC's kubelet lines (the
  # pod also mounts other volumes, e.g. snapshots), or nil if either is absent.
  def parse_volume_stats(text) do
    stats =
      for line <- String.split(text, "\n"),
          line =~ ~s(persistentvolumeclaim="qdrant-storage-),
          [name, value] <-
            [
              Regex.run(~r/^kubelet_volume_stats_(used|capacity)_bytes\{[^}]*\}\s+(\S+)/, line,
                capture: :all_but_first
              ) || []
            ],
          {num, _} <- [Float.parse(value)],
          into: %{},
          do: {String.to_existing_atom(name), trunc(num)}

    case stats do
      %{used: _, capacity: _} -> stats
      _ -> nil
    end
  end

  defp report_reconciled(changed) do
    Logger.info("qdrant config reconciled: #{Enum.join(changed, ", ")}")
    :telemetry.execute([:engram, :qdrant, :config_reconciled], %{count: 1}, %{changed: changed})
  end

  defp patch_collection(_col, body) when map_size(body) == 0, do: :ok

  defp patch_collection(col, body) do
    instrument(:update_collection, fn ->
      case Req.patch("#{base_url()}/collections/#{col}", [json: body] ++ req_opts()) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  `GET /` -> the server's `Version`, or nil when unreadable: strict mode is
  then skipped (not guessed), and the next call tries again.
  """
  def server_version do
    with {:ok, %{status: 200, body: %{"version" => v}}} <-
           Req.get(base_url() <> "/", req_opts(:search)),
         {:ok, version} <- Version.parse(v) do
      version
    else
      _ -> nil
    end
  end

  @doc """
  `server_version/0`, node-cached for 10 minutes (it changes only on a Qdrant
  upgrade; nil is not cached, so an unreadable server is retried next call).
  """
  def cached_server_version,
    do: Engram.Cache.fetch(:qdrant_version, base_url(), &server_version/0)

  # Strict mode refusing a write for disk or memory (Qdrant >= 1.18.1):
  # `CollectionError::StrictMode` -> `StorageError::BadRequest`, HTTP 400,
  # message from `check_disk_usage` / the resident-memory check in
  # lib/collection/src/operations/verification/mod.rs. Searches and deletes
  # are never refused (delete ops are not "disk/memory-consuming"); deletes
  # map it anyway so a future Qdrant that does refuse them is handled alike.
  @backpressure ~r/(Disk usage|Resident memory usage) is at \d+% of total/

  # Qdrant 1.19+ node-wide quota (`/quotas`) refusing a write: HTTP 507, whose
  # only producer is StorageError::InsufficientStorage (src/actix/helpers.rs),
  # so the status alone is the signal, whatever the wording
  # (lib/shard/src/quota/check.rs). Point deletes are never refused; payload
  # key and vector deletes are (they rewrite the point).
  defp write_error(507, _body), do: {:error, :qdrant_backpressure}

  defp write_error(400, %{"status" => %{"error" => message}} = body) when is_binary(message) do
    if message =~ @backpressure, do: {:error, :qdrant_backpressure}, else: {:error, {400, body}}
  end

  defp write_error(status, body), do: {:error, {status, body}}

  @doc """
  How full Qdrant is, in whole percent, with the strict-mode limits it is
  measured against: `%{disk: pct | nil, heap: pct | nil, limits: limits}`.
  Disk is the storage volume from Qdrant Cloud `/sys_metrics`; heap is
  `memory_resident_bytes` from `/metrics` (the jemalloc figure strict mode
  checks) over `QDRANT_MEMORY_LIMIT_BYTES`. nil = unknown (self-host has no
  `/sys_metrics`; no limit configured), which callers treat as "not full".
  Node-cached for 60s, so the age of a reading is bounded by the TTL.
  """
  def pressure, do: Engram.Cache.fetch(:qdrant_pressure, base_url(), &read_pressure/0)

  @doc "Drop this node's cached `pressure/0` reading."
  def forget_pressure, do: Engram.Cache.evict_local(:qdrant_pressure, base_url())

  @doc """
  A fresh `pressure/0` reading (the poller), refreshing the cache. `memory`:
  a `collection_memory/1` result to reuse, or `:fetch`.
  """
  # ponytail: every node reads /sys_metrics, /metrics and /memory once a
  # minute. Cheap at a handful of nodes; share the poller's reading over
  # PubSub if the fleet grows.
  def read_pressure(memory \\ :fetch) do
    volume = volume_stats()

    reading = %{
      disk: disk_percent(volume),
      heap: heap_percent(),
      limits: strict_limits(collection(), volume, memory)
    }

    Engram.Cache.put(:qdrant_pressure, base_url(), reading)
    reading
  end

  @static_limits %{disk: %{percent: 85, reserve: nil}, heap: %{percent: 85, reserve: nil}}

  @doc """
  The worker response to `{:error, :qdrant_backpressure}`: an Oban snooze
  (no attempt consumed), jittered 31..90s so parked jobs do not return to a
  recovering Qdrant in one wave. Emits `[:engram, :qdrant, :backpressure]`.
  """
  def backpressure_snooze(reason) when reason in [:preflight, :refused] do
    :telemetry.execute([:engram, :qdrant, :backpressure], %{count: 1}, %{reason: reason})
    {:snooze, 30 + :rand.uniform(60)}
  end

  @doc """
  True when disk or heap is within `QDRANT_PREFLIGHT_MARGIN_POINTS` (default
  5) of its strict-mode limit, i.e. about to be refused. Unknown is never over.
  """
  def over_pressure?(%{disk: disk, heap: heap} = reading) do
    limits = Map.get(reading, :limits, @static_limits)
    margin = ServiceConfig.get(:qdrant_preflight_margin_points, 5)

    at_or_over?(disk, limits.disk.percent - margin) or
      at_or_over?(heap, limits.heap.percent - margin)
  end

  defp at_or_over?(pct, limit), do: is_integer(pct) and pct >= limit

  defp disk_percent(%{used: used, capacity: cap}) when cap > 0, do: div(used * 100, cap)
  defp disk_percent(_), do: nil

  defp heap_percent do
    with limit when is_integer(limit) and limit > 0 <-
           ServiceConfig.get(:qdrant_memory_limit_bytes),
         {:ok, %{status: 200, body: text}} when is_binary(text) <-
           Req.get(base_url() <> "/metrics", [decode_body: false] ++ req_opts(:search)),
         [_, value] <- Regex.run(~r/^memory_resident_bytes\s+(\S+)/m, text),
         {resident, _} <- Float.parse(value) do
      div(trunc(resident) * 100, limit)
    else
      _ -> nil
    end
  end

  @doc """
  Upsert a batch of points. Each point: %{id: uuid_string, vector: [float], payload: map}.
  """
  def upsert_points(col \\ nil, points) do
    col = col || collection()

    serialized = Enum.map(points, fn p -> %{id: p.id, vector: p.vector, payload: p.payload} end)
    opts = write_opts(%{points: serialized})

    instrument(:upsert, fn ->
      case Req.put("#{base_url()}/collections/#{col}/points", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Replace the given named vectors on existing points; vectors not named and
  the payload are untouched. `points` are `%{id, vector: %{name => v}}`.
  """
  def update_vectors(col \\ nil, points) do
    col = col || collection()
    serialized = Enum.map(points, fn p -> %{id: p.id, vector: p.vector} end)
    opts = write_opts(%{points: serialized})

    instrument(:update_vectors, fn ->
      case Req.put("#{base_url()}/collections/#{col}/points/vectors", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Patch (overwrite-or-add) the given payload keys on the listed point ids.
  Vectors are untouched — this is the cost-free path for re-shaping payloads
  without re-running the embedder. Empty `point_ids` is a no-op.
  """
  def set_payload(col \\ nil, point_ids, payload)
  def set_payload(_col, [], _payload), do: :ok

  def set_payload(col, point_ids, payload) when is_list(point_ids) and is_map(payload) do
    col = col || collection()
    opts = write_opts(%{points: point_ids, payload: payload})

    instrument(:set_payload, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/payload", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Patch (overwrite-or-add) payload keys on EVERY point matching the
  `{user_id, vault_id, path_hmac}` filter — vectors untouched. The cost-free
  way to re-path a note's points after a rename without re-running the
  embedder (#746). Triple-scope is mandatory: filtering on `path_hmac` alone
  could cross tenants if two users' folded HMACs collide.
  """
  def set_payload_by_filter(col \\ nil, user_id, vault_id, path_hmac, payload)
      when is_map(payload) do
    col = col || collection()

    filter = %{
      must: [
        %{key: "user_id", match: %{value: user_id}},
        %{key: "vault_id", match: %{value: vault_id}},
        %{key: "path_hmac", match: %{value: path_hmac}}
      ]
    }

    opts = write_opts(%{filter: filter, payload: payload})

    instrument(:set_payload, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/payload", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # #590: note-metadata fields that leaked as plaintext into payloads written
  # before the fix. Canonical list — the mix task and prod rpc both go through
  # delete_leaked_plaintext_keys/1 so this never drifts.
  @leaked_plaintext_keys ["source_path", "folder", "tags"]

  @doc """
  #590 backfill convenience: strip the known leaked plaintext keys
  (#{inspect(@leaked_plaintext_keys)}) from every existing point.

  Lives here (not in the Mix task) so it is callable from a release rpc,
  where `Mix` is not loaded:

      /app/bin/engram rpc 'Engram.Vector.Qdrant.delete_leaked_plaintext_keys() |> IO.inspect()'
  """
  def delete_leaked_plaintext_keys(col \\ nil),
    do: delete_payload_keys(col, @leaked_plaintext_keys)

  @doc """
  #590 backfill: delete the named payload keys from EVERY point in the
  collection (match-all filter). Vectors and all other payload keys are
  untouched — the cost-free way to strip leaked plaintext
  (`source_path`/`folder`/`tags`) from points written before the fix.
  Empty `keys` is a no-op.
  """
  def delete_payload_keys(col \\ nil, keys)
  def delete_payload_keys(_col, []), do: :ok

  def delete_payload_keys(col, keys) when is_list(keys) do
    col = col || collection()
    opts = write_opts(%{keys: keys, filter: %{must: []}})

    instrument(:delete_payload, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/payload/delete", opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Delete the listed point ids outright. Empty list is a no-op.

  The identity-safe delete: point ids come from `chunks.qdrant_point_id`, so
  this reaches a note's points no matter what its `path_hmac` has since become.
  `delete_by_note/4` cannot — a rename retags the note row while the points keep
  the old hmac, and the filter then matches nothing. Callers use both.
  """
  def delete_points(col \\ nil, point_ids)
  def delete_points(_col, []), do: :ok

  def delete_points(col, point_ids) when is_list(point_ids) do
    col = col || collection()
    opts = write_opts(%{points: point_ids})

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
        # 404 is a missing COLLECTION, so there is nothing to delete. Missing
        # point ids come back 200. Treating it as an error made DeleteNoteIndex
        # (#1608, which retries now rather than swallowing) burn its attempts
        # on a stack that has never indexed anything.
        {:ok, %{status: status}} when status in [200, 404] -> :ok
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Delete all points for a given user+vault+path-hmac combination.

  T3.2 — `path_hmac` is the base64-encoded HMAC of the note path under the
  user's filter key. Qdrant payloads carry `path_hmac` as a plaintext-safe
  filter key alongside the encrypted `source_path` (Phase B.2.4).
  """
  def delete_by_note(col \\ nil, user_id, vault_id, path_hmac) do
    col = col || collection()

    filter = %{
      must: [
        %{key: "user_id", match: %{value: user_id}},
        %{key: "vault_id", match: %{value: vault_id}},
        %{key: "path_hmac", match: %{value: path_hmac}}
      ]
    }

    opts = write_opts(%{filter: filter})

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
        # Missing collection: nothing to delete. See `delete_points/2`.
        {:ok, %{status: status}} when status in [200, 404] -> :ok
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Exact count of points matching `{user_id, vault_id, path_hmac}`. Used by the
  repath worker (#746) to confirm points exist before/after a payload PATCH and
  to detect an embedded note whose points went missing.
  """
  def count_by_note(col \\ nil, user_id, vault_id, path_hmac) do
    col = col || collection()

    filter = %{
      must: [
        %{key: "user_id", match: %{value: user_id}},
        %{key: "vault_id", match: %{value: vault_id}},
        %{key: "path_hmac", match: %{value: path_hmac}}
      ]
    }

    opts = [json: %{filter: filter, exact: true}] ++ req_opts()

    instrument(:count, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/count", opts) do
        {:ok, %{status: 200, body: %{"result" => %{"count" => count}}}} -> {:ok, count}
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Delete every point owned by `user_id` across all of their vaults. Used by
  account delete (soft and hard) and by OrphanSweep — single Qdrant call
  regardless of vault count. `purpose` picks the `req_opts/1` profile: a user
  or Clerk delete runs in a request and passes `:search` to fail fast.
  """
  def delete_by_user(col \\ nil, user_id, purpose \\ :indexing) do
    col = col || collection()

    filter = %{must: [%{key: "user_id", match: %{value: user_id}}]}
    opts = write_opts(%{filter: filter}, purpose)

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
        # Missing collection: nothing to delete. See `delete_points/2`.
        {:ok, %{status: status}} when status in [200, 404] -> :ok
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Delete all points for a given user+vault combination (vault-level cleanup).
  """
  def delete_by_vault(col \\ nil, user_id, vault_id) do
    col = col || collection()

    filter = %{
      must: [
        %{key: "user_id", match: %{value: user_id}},
        %{key: "vault_id", match: %{value: vault_id}}
      ]
    }

    opts = write_opts(%{filter: filter})

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
        # Missing collection: nothing to delete. See `delete_points/2`.
        {:ok, %{status: status}} when status in [200, 404] -> :ok
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  T3.7 — scrolls all points matching a filter, paginated. Used by the
  DEK-rotation orchestrator to re-encrypt every point in a user's tenant
  without touching vectors.

  Options:
    * `:filter` — a Qdrant filter map, e.g. `%{must: [%{key: "user_id", match: %{value: 42}}]}`
    * `:limit` — page size (default 200)
    * `:offset` — opaque page-token returned from a prior call's `next_page_offset` (nil on first call)
    * `:with_payload` — defaults to `true`
    * `:with_vector` — defaults to `false`

  Returns `{:ok, %{points: [...], next_page_offset: term() | nil}} | {:error, term()}`.
  """
  def scroll(col \\ nil, opts) when is_list(opts) do
    collection_name = col || collection()
    url = "#{base_url()}/collections/#{collection_name}/points/scroll"

    body = %{
      filter: Keyword.fetch!(opts, :filter),
      with_payload: Keyword.get(opts, :with_payload, true),
      with_vector: Keyword.get(opts, :with_vector, false),
      limit: Keyword.get(opts, :limit, 200)
    }

    body =
      case Keyword.get(opts, :offset) do
        nil -> body
        offset -> Map.put(body, :offset, offset)
      end

    instrument(:scroll, fn ->
      case Req.post(url, [json: body] ++ req_opts()) do
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"result" => %{"points" => points, "next_page_offset" => next}}
         }} ->
          {:ok, %{points: points, next_page_offset: next}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:qdrant_scroll, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Vector similarity search. Returns list of result structs with score + payload.

  Options:
  - `:user_id`     — filter to this user's points (required for tenant isolation)
  - `:vault_id`    — filter to a specific vault (omit for cross-vault search)
  - `:limit`       — number of results (default 5)
  - `:folder_hmac` — filter to points whose folder_hmac equals this value
                     (Phase B.2.3 — base64-encoded HMAC, no plaintext folder)
  - `:tags_hmac`   — filter to points with ANY of these tag HMACs
                     (Phase B.2.3 — base64-encoded list, no plaintext tags)
  """
  def search(col \\ nil, vector, search_opts) do
    col = col || collection()

    instrument(:search, fn ->
      do_search(col, [json: search_body(vector, search_opts)] ++ req_opts(:search))
    end)
  end

  @doc false
  def search_body(vector, search_opts) do
    base = %{
      query: vector,
      using: "dense",
      filter: build_tenant_filter(search_opts),
      limit: Keyword.get(search_opts, :limit, 5),
      with_payload: true
    }

    base
    |> then(fn b ->
      case quantization_params(search_opts) do
        nil -> b
        params -> Map.put(b, :params, params)
      end
    end)
    |> maybe_with_vector(search_opts)
  end

  # Per-query quantization params. full_precision bypasses binary quant
  # (exact-cosine traversal over full floats); otherwise the binary funnel.
  defp quantization_params(search_opts) do
    cond do
      Keyword.get(search_opts, :full_precision, false) ->
        %{quantization: %{ignore: true}}

      binary_quantization_enabled?() ->
        %{quantization: %{rescore: true, oversampling: 3.0}}

      true ->
        nil
    end
  end

  defp maybe_with_vector(body, search_opts) do
    if Keyword.get(search_opts, :with_vector, false),
      do: Map.put(body, :with_vector, ["dense"]),
      else: body
  end

  @doc false
  # Public for filter-shape tests only (test/engram/vector/qdrant_filter_test.exs).
  # Extracted from search/3 so all three query shapes share tenant + OKF
  # frontmatter filtering.
  def build_tenant_filter(search_opts) do
    user_id = Keyword.fetch!(search_opts, :user_id)
    vault_id = Keyword.get(search_opts, :vault_id)
    tags_hmac = Keyword.get(search_opts, :tags_hmac)
    folder_hmac = Keyword.get(search_opts, :folder_hmac)
    type_hmac = Keyword.get(search_opts, :type_hmac)

    must = [%{key: "user_id", match: %{value: user_id}}]
    # `vault_id` accepts one id or a set. The set form is what a multi-vault
    # OAuth grant (and a subset-restricted API key) needs: without it the only
    # options were one query per vault or dropping the filter entirely, and
    # dropping it leaks every vault the credential was scoped away from (#729).
    # `vault_id` is already a keyword payload index (@payload_index_fields), so
    # `any` needs no new index — same shape as tags_hmac below.
    must =
      case vault_id do
        nil -> must
        id when is_binary(id) -> must ++ [%{key: "vault_id", match: %{value: id}}]
        ids when is_list(ids) -> must ++ [%{key: "vault_id", match: %{any: ids}}]
      end

    must = if tags_hmac, do: [%{key: "tags_hmac", match: %{any: tags_hmac}} | must], else: must

    must =
      if folder_hmac, do: [%{key: "folder_hmac", match: %{value: folder_hmac}} | must], else: must

    must =
      if type_hmac, do: [%{key: "type_hmac", match: %{value: type_hmac}} | must], else: must

    must
    |> add_range_clause("fm_timestamp", search_opts, :fm_timestamp_gte, :fm_timestamp_lte)
    |> add_range_clause("fm_created", search_opts, :fm_created_gte, :fm_created_lte)
    |> then(&%{must: &1})
  end

  defp add_range_clause(must, key, opts, gte_key, lte_key) do
    range =
      %{}
      |> maybe_put_bound(:gte, Keyword.get(opts, gte_key))
      |> maybe_put_bound(:lte, Keyword.get(opts, lte_key))

    if range == %{}, do: must, else: must ++ [%{key: key, range: range}]
  end

  defp maybe_put_bound(range, _bound, nil), do: range
  defp maybe_put_bound(range, bound, value), do: Map.put(range, bound, value)

  @doc """
  Keyword-only search against the sparse `keyword` vector. `sparse` is
  `%{indices: [u32], values: [float]}`. Same options as `search/3`.
  """
  def sparse_search(col \\ nil, sparse, search_opts) do
    col = col || collection()

    instrument(:sparse_search, fn ->
      do_search(col, [json: sparse_search_body(sparse, search_opts)] ++ req_opts(:search))
    end)
  end

  @doc false
  def sparse_search_body(sparse, search_opts) do
    %{
      query: %{indices: sparse.indices, values: sparse.values},
      using: "keyword",
      filter: build_tenant_filter(search_opts),
      limit: Keyword.get(search_opts, :limit, 5),
      with_payload: true
    }
    |> maybe_with_vector(search_opts)
  end

  # Qdrant's own RRF default, kept so fused scores read as before.
  @rrf_k 2

  @doc """
  Hybrid search: the dense and keyword legs run as one `/points/query/batch`
  request and are fused here by `Engram.Search.Fusion.rrf/2` (k = 2), so
  fused-score ties break the same way every time (server-side RRF orders
  them arbitrarily). `sparse` is `%{indices, values}`. Tenant filter is
  applied to BOTH legs (load-bearing: the sparse inverted index is global).
  Each leg fetches `:limit` points; the fused list is cut back to `:limit`.
  """
  def hybrid_search(col \\ nil, dense, sparse, search_opts) do
    col = col || collection()
    limit = Keyword.get(search_opts, :limit, 5)

    instrument(:hybrid_search, fn ->
      opts = [json: hybrid_search_body(dense, sparse, search_opts)] ++ req_opts(:search)

      with {:ok, legs} <- do_query(col, "/points/query/batch", opts, &batch_results/1) do
        fused =
          legs
          |> Enum.map(fn leg -> Enum.map(leg, &Map.put(&1, :id, &1.qdrant_id)) end)
          |> Fusion.rrf(@rrf_k)
          |> Enum.take(limit)
          |> Enum.map(&Map.delete(&1, :id))

        {:ok, fused}
      end
    end)
  end

  @doc false
  def hybrid_search_body(dense, sparse, search_opts) do
    filter = build_tenant_filter(search_opts)
    limit = Keyword.get(search_opts, :limit, 5)

    dense_leg =
      %{query: dense, using: "dense", filter: filter, limit: limit, with_payload: true}
      |> then(fn leg ->
        case quantization_params(search_opts) do
          nil -> leg
          params -> Map.put(leg, :params, params)
        end
      end)
      |> maybe_with_vector(search_opts)

    sparse_leg =
      %{
        query: %{indices: sparse.indices, values: sparse.values},
        using: "keyword",
        filter: filter,
        limit: limit,
        with_payload: true
      }
      |> maybe_with_vector(search_opts)

    %{searches: [dense_leg, sparse_leg]}
  end

  @doc """
  The ids among `point_ids` whose points hold a `dense` vector. A recommend
  positive without one is refused for the whole request, and sparse-only
  points (frontmatter, data, canvas, base) are normal. One page: the
  `has_id` filter caps the matches at `length(point_ids)`.
  """
  def dense_point_ids(col \\ nil, point_ids)
  def dense_point_ids(_col, []), do: {:ok, []}

  def dense_point_ids(col, point_ids) do
    filter = %{must: [%{has_id: point_ids}, %{has_vector: "dense"}]}

    with {:ok, %{points: points}} <-
           scroll(col, filter: filter, with_payload: false, limit: length(point_ids)) do
      {:ok, Enum.map(points, & &1["id"])}
    end
  end

  @doc """
  Points similar to the given stored points: Qdrant averages their dense
  vectors (`average_vector`) and searches with the centroid. No embed call.
  The given points are excluded from the results. Same options as `search/3`.
  """
  def recommend(col \\ nil, point_ids, search_opts) do
    col = col || collection()

    instrument(:recommend, fn ->
      do_search(col, [json: recommend_body(point_ids, search_opts)] ++ req_opts(:search))
    end)
  end

  @doc false
  def recommend_body(point_ids, search_opts) do
    %{
      query: %{recommend: %{positive: point_ids, strategy: "average_vector"}},
      using: "dense",
      filter: Map.put(build_tenant_filter(search_opts), :must_not, [%{has_id: point_ids}]),
      limit: Keyword.get(search_opts, :limit, 5),
      with_payload: true
    }
    |> then(fn b ->
      case quantization_params(search_opts) do
        nil -> b
        params -> Map.put(b, :params, params)
      end
    end)
    |> maybe_with_vector(search_opts)
  end

  # The body is decoded in Rust (`Engram.Native.json_decode/1`): with vectors
  # requested it is ~200 x 1024 floats, 2.3 MB of JSON that took Jason ~290 ms
  # per search, ten times the MMR pass that consumes it.
  # The `qdrant.query` span covers the HTTP call only, with no attributes
  # (the body holds the query vector and tenant filter).
  defp do_search(col, opts), do: do_query(col, "/points/query", opts, &{:ok, search_results(&1)})

  # `/points/query/batch` answers a list of `%{"points" => [...]}`, one per
  # request in order; it comes back as a list of hit lists.
  defp batch_results(result) when is_list(result), do: {:ok, Enum.map(result, &search_results/1)}
  defp batch_results(other), do: {:error, {200, other}}

  defp do_query(col, path, opts, parse) do
    resp =
      Tracer.with_span "qdrant.query" do
        Req.post(
          "#{base_url()}/collections/#{col}#{path}",
          opts ++ [params: [timeout: server_timeout_s(:search)], decode_body: false]
        )
        |> Engram.Observability.Otel.mark_http_result()
      end

    case resp do
      {:ok, %{status: 200, body: raw}} when is_binary(raw) ->
        case Engram.Native.json_decode(raw) do
          {:ok, %{"result" => result}} -> parse.(result)
          {:ok, other} -> {:error, {200, other}}
          {:error, _} -> {:error, {200, raw}}
        end

      {:ok, %{status: status, body: body} = resp} ->
        {:error, {status, decode_error_body(resp, body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What Req's default decoding produced before `decode_body: false`: JSON by
  # content type is decoded, anything else stays raw.
  defp decode_error_body(resp, body) when is_binary(body) do
    json? = Enum.any?(Req.Response.get_header(resp, "content-type"), &(&1 =~ "json"))

    case json? && Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp decode_error_body(_resp, body), do: body

  defp search_results(result) do
    points = if is_list(result), do: result, else: result["points"] || []

    Enum.map(points, fn p ->
      payload = p["payload"] || %{}

      %{
        score: p["score"],
        vector: get_in(p, ["vector", "dense"]),
        text: Map.get(payload, "text"),
        title: Map.get(payload, "title"),
        heading_path: Map.get(payload, "heading_path"),
        # #590: new points carry no plaintext source_path/tags — these
        # read nil/[] and Search.rehydrate_display_fields/2 refills them
        # from the encrypted notes row. Kept as a fallback for old points
        # not yet stripped by the backfill (delete_leaked_plaintext_keys).
        source_path: Map.get(payload, "source_path"),
        tags: Map.get(payload, "tags") || [],
        vault_id: Map.get(payload, "vault_id"),
        qdrant_id: p["id"],
        # Nonce keys are only present on encrypted-vault chunks; nil otherwise.
        text_nonce: Map.get(payload, "text_nonce"),
        title_nonce: Map.get(payload, "title_nonce"),
        heading_path_nonce: Map.get(payload, "heading_path_nonce"),
        # T3.6 — present on AAD-bound payloads (>= v2). Drives the
        # bind-vs-empty AAD decision in `Engram.Crypto.qdrant_aad/3`.
        aad_version: Map.get(payload, "aad_version")
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end)
  end
end
