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
    guards (`max_disk_usage_percent`, `max_resident_memory_percent`) to 100
    and, on Qdrant Cloud, every hard limit we set (`QdrantLayout.desired_strict/1`,
    plus both byte breakers) to a ceiling no request reaches. `enabled` and
    Qdrant Cloud's own unindexed-filter guard are left as they are.
  - QDRANT_BACKPRESSURE_PREFLIGHT: false = EmbedNote never pauses for pressure.
  """

  alias Engram.Logger.Metadata
  alias Engram.Search.Fusion
  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId
  alias Engram.Vector.PayloadKeys
  alias Engram.Vector.QdrantLayout

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @default_url "http://localhost:6333"
  @default_collection "obsidian_notes"

  # The payload indexes (legacy and v5, by server version) are
  # `QdrantLayout.payload_indexes/2`.

  # The largest request shapes any caller sends, so the Qdrant Cloud strict
  # limits (`QdrantLayout.desired_strict/1`) can sit above them with headroom.
  # A caller with an unbounded input (a note's point ids, a tag list) chunks
  # or refuses to fit; test/engram/vector/qdrant_strict_callers_test.exs
  # pins both sides.
  @max_page 4096
  @max_ids 2048
  @max_write_batch 64

  # No @specs on these constant accessors: dialyzer's :underspecs flags
  # `pos_integer()` against the literal's success typing.

  @doc "Largest `limit` a scroll or query sends (OrphanSweep's id-only page)."
  def max_page, do: @max_page

  @doc "Largest id or value list in one `has_id` / `match.any` condition."
  def max_ids, do: @max_ids

  @doc "Largest point batch one upsert or vector update sends."
  def max_write_batch, do: @max_write_batch

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
  profile's client `receive_timeout`. Floored at 1 (Qdrant reads 0 as no
  limit) and capped at `QdrantLayout.max_timeout_s/0`.
  """
  @spec server_timeout_s(:search | :indexing) :: pos_integer()
  # Clamped to the Cloud strict `max_timeout`: above it Qdrant 400s the
  # search outright. The client `receive_timeout` keeps the configured budget.
  def server_timeout_s(:search) do
    (div(ServiceConfig.get(:qdrant_search_timeout, 5_000), 1000) - 1)
    |> max(1)
    |> min(QdrantLayout.max_timeout_s())
  end

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
    case layout_version() do
      :unknown -> ensure_existing_only(col, dims)
      version -> ensure_with_layout(col, dims, version)
    end
  end

  # The app manages the layout but cannot read the server version: never
  # create a collection with a guessed (pre-1.19.2) layout, which on a 1.19.2
  # server would keep the wrong index params for good. An existing collection
  # is still verified; a missing one is an error, retried on the next call.
  defp ensure_existing_only(col, dims) do
    case collection_info(col) do
      {:ok, _} -> ensure_with_layout(col, dims, nil)
      {:error, {404, _}} -> {:error, :qdrant_version_unknown}
      {:error, _} = error -> error
    end
  end

  defp ensure_with_layout(col, dims, version) do
    case create_collection(col, dims, version) do
      {:ok, :created} ->
        with :ok <- ensure_payload_indexes(col, MapSet.new(), version), do: reconciled(col)

      {:ok, {:exists, :unknown}} ->
        {:ok, :unverified}

      {:ok, {:exists, indexed}} ->
        with :ok <- ensure_payload_indexes(col, indexed, version), do: reconciled(col)

      {:error, _} = error ->
        error
    end
  end

  # The server version the layout is chosen for (`QdrantLayout.tenant_layout?/1`).
  # Only while the app manages the layout (`:qdrant_reconcile_config`, the
  # same switch as the PATCH reconcile; off in tests, so Bypass suites see no
  # extra GET, and nil keeps the pre-1.19.2 layout). `:unknown` when managed
  # but unreadable.
  defp layout_version do
    if ServiceConfig.get(:qdrant_reconcile_config, true) do
      with nil <- server_version() do
        Logger.warning("qdrant version unreadable, not creating a collection this time")
        :unknown
      end
    end
  end

  # Storage/safety params are best-effort: a failed reconcile is logged and
  # retried next boot, never a reason to stop indexing. Only the payload
  # indexes above gate `:verified`, because strict mode 400s without them.
  defp reconciled(col) do
    _ = reconcile_config(col)
    {:ok, :verified}
  end

  defp create_collection(col, dims, version) do
    body =
      dims
      |> QdrantLayout.create_params(v5_payload_format?(), version)
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
  # An index that exists is never re-created, so an existing collection keeps
  # its index params; only a missing field gets the version's schema.
  defp ensure_payload_indexes(col, indexed, version) do
    missing =
      version
      |> QdrantLayout.payload_indexes(v5_payload_format?())
      |> Enum.reject(fn {field, _} -> MapSet.member?(indexed, field) end)

    last = length(missing) - 1

    # Only the last create waits. Index ops apply in order on each shard, so
    # once the last is built every earlier one is too, and nine waited
    # fsync-bound builds in a row became one (the #2064 CI stall; verified on
    # 1.19.2 over 3000 points on 2 shards).
    missing
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{field, schema}, i}, :ok ->
      case create_payload_index(col, field, schema, i == last) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp create_payload_index(col, field, schema, wait?) do
    # A waited create blocks until the index is built over every existing
    # point, which on a large collection outlasts the default indexing
    # budget. A timeout here fails `ensure_collection` (deliberately not
    # memoised), so every retrying job would re-issue the same build. Give it
    # its own.
    opts =
      [
        json: %{field_name: field, field_schema: schema},
        params: [wait: wait?],
        receive_timeout: 120_000
      ] ++ req_opts()

    instrument(:create_payload_index, fn ->
      case Req.put("#{base_url()}/collections/#{col}/index", opts) do
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

  @doc """
  `:cloud` for a Qdrant Cloud URL (`*.cloud.qdrant.io`, with or without a
  scheme), where the strict hard limits (`QdrantLayout.desired_strict/1`)
  apply; `:self_host` otherwise. `QDRANT_STRICT_PROFILE` (`:qdrant_strict_profile`)
  overrides it, so staging (self-host) can rehearse the Cloud limits.
  """
  @spec deployment(String.t()) :: :cloud | :self_host
  def deployment(url) do
    case ServiceConfig.get(:qdrant_strict_profile) do
      profile when profile in [:cloud, :self_host] -> profile
      _ -> deployment_by_host(url)
    end
  end

  @doc "`:override` when `:qdrant_strict_profile` decides `deployment/1`, `:host` otherwise."
  @spec deployment_source() :: :override | :host
  def deployment_source,
    do:
      if(ServiceConfig.get(:qdrant_strict_profile) in [:cloud, :self_host],
        do: :override,
        else: :host
      )

  # A scheme-less URL parses with no host; read it as `//host:port` then.
  defp deployment_by_host(url) do
    host = URI.parse(url).host || URI.parse("//" <> url).host || ""
    if String.ends_with?(host, ".cloud.qdrant.io"), do: :cloud, else: :self_host
  end

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

      Logger.info("qdrant strict profile #{deployment(base_url())} (#{deployment_source()})")

      limits = strict_limits(col, volume_stats())

      diff =
        QdrantLayout.diff(
          info["config"] || %{},
          QdrantLayout.desired(
            version,
            limits,
            strict_mode?(),
            deployment(base_url()),
            tenant_graph?(info, version)
          )
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

  # Task 18.1 flips `:qdrant_tenant_graph` once drop-legacy-fields leaves no
  # legacy `user_id` point; until then the global graph stays (one user would
  # otherwise be two disconnected subgraphs, legacy and v5).
  defp tenant_graph?(info, version) do
    switch? = ServiceConfig.get(:qdrant_tenant_graph, false)
    graph? = QdrantLayout.tenant_graph?(info, version, switch?)

    if switch? and not graph? and QdrantLayout.tenant_layout?(version),
      do: Logger.warning("qdrant tenant graph skipped: the `u` index is not is_tenant")

    graph?
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
      |> QdrantLayout.desired(limits, strict_mode?(), deployment(base_url()))
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
  #
  # The capacity breakers are backpressure too (`max_points_count`, the byte
  # sizes; `check_collection_size_limit` in verification/update.rs): a plain
  # error makes EmbedNote retry, re-embedding (and re-paying Voyage) only to
  # be refused again; backpressure snoozes with the vectors retained.
  # Strings captured from 1.19.2 (qdrant_backpressure_test).
  @backpressure ~r/(Disk usage|Resident memory usage) is at \d+% of total|Max points count limit of \d+ reached|Max (vector|payload) storage size limit of [\d.]+MB reached/

  # A request-shape refusal (a limit, condition or filter over its strict
  # cap) is a code bug the same request repeats forever, so it is NOT
  # backpressure: it stays a plain error (attempts count, then the poison
  # park), logged and counted for the alert (review N1).
  @shape_refusal ~r/Limit exceeded \d+ > \d+ for |Condition size limit reached|Filter condition limit reached/

  # Qdrant 1.19+ node-wide quota (`/quotas`) refusing a write: HTTP 507, whose
  # only producer is StorageError::InsufficientStorage (src/actix/helpers.rs),
  # so the status alone is the signal, whatever the wording
  # (lib/shard/src/quota/check.rs). Point deletes are never refused; payload
  # key and vector deletes are (they rewrite the point).
  defp write_error(507, _body), do: {:error, :qdrant_backpressure}

  defp write_error(400, %{"status" => %{"error" => message}} = body) when is_binary(message) do
    cond do
      message =~ @backpressure ->
        {:error, :qdrant_backpressure}

      message =~ @shape_refusal ->
        Logger.error("qdrant strict-mode refused a request shape: #{message}")
        :telemetry.execute([:engram, :qdrant, :strict_shape_refusal], %{count: 1}, %{})
        {:error, {400, body}}

      true ->
        {:error, {400, body}}
    end
  end

  defp write_error(status, body), do: {:error, {status, body}}

  # A 200 is not always applied: with `wait=true`, a server `timeout` that
  # expires first answers 200 with `result.status = "wait_timeout"`
  # (`shard_ops.rs`). The op is queued and will apply, but its points may be
  # invisible now, which is the race `wait=true` exists to close, so it is an
  # error the caller must not stamp on. EmbedNote snoozes on it; the retry
  # reuses the retained vectors, so Voyage is not paid again.
  defp applied(%{"result" => %{"status" => "wait_timeout"}}), do: wait_timeout()

  defp applied(%{"result" => results}) when is_list(results) do
    if Enum.any?(results, &match?(%{"status" => "wait_timeout"}, &1)),
      do: wait_timeout(),
      else: :ok
  end

  defp applied(_body), do: :ok

  defp wait_timeout do
    :telemetry.execute([:engram, :qdrant, :wait_timeout], %{count: 1}, %{})
    {:error, :qdrant_wait_timeout}
  end

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
  The Oban answer for a waited write that came back `:qdrant_wait_timeout`
  (queued, not applied): snooze without burning an attempt, so no worker
  reaches a final-attempt fallback (Repath's is a paid re-embed). Every
  write is idempotent, so the retry is safe. The event was already emitted
  by the write.
  """
  def wait_timeout_snooze, do: {:snooze, 30 + :rand.uniform(60)}

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
        {:ok, %{status: 200, body: body}} -> applied(body)
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
        {:ok, %{status: 200, body: body}} -> applied(body)
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Patch (overwrite-or-add) the given payload keys on the listed point ids.
  Vectors are untouched — this is the cost-free path for re-shaping payloads
  without re-running the embedder. Empty `point_ids` is a no-op.

  Ids that name no point are skipped, not an error: the ids come from
  `chunks` rows, and an orphaned row must not fail a rotation or a refresh.
  A `points` list answers 404 for a missing id; a `has_id` filter does not.
  """
  def set_payload(col \\ nil, point_ids, payload)
  def set_payload(_col, [], _payload), do: :ok

  def set_payload(col, point_ids, payload) when is_list(point_ids) and is_map(payload) do
    col = col || collection()
    opts = write_opts(%{filter: ids_filter(point_ids), payload: payload})

    instrument(:set_payload, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/payload", opts) do
        {:ok, %{status: 200, body: body}} -> applied(body)
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  REPLACE the whole payload of the listed points (`PUT /points/payload`).
  The v5 refresh path: a v5 payload omits absent and default keys, so a
  merge (`set_payload/3`) would leave a removed key on the point forever.
  Empty `point_ids` is a no-op; missing ids are skipped (`set_payload/3`).
  """
  def overwrite_payload(col \\ nil, point_ids, payload)
  def overwrite_payload(_col, [], _payload), do: :ok

  def overwrite_payload(col, point_ids, payload) when is_list(point_ids) and is_map(payload) do
    col = col || collection()
    opts = write_opts(%{filter: ids_filter(point_ids), payload: payload})

    instrument(:set_payload, fn ->
      case Req.put("#{base_url()}/collections/#{col}/points/payload", opts) do
        {:ok, %{status: 200, body: body}} -> applied(body)
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  A different payload per point (`[{id, payload}]`), merged like
  `set_payload/3`, in two requests whatever the count: one `/points/batch`
  of set_payload ops without `wait`, then one waited barrier. Qdrant runs a
  batch's ops one by one with the request's `wait` (`do_batch_update_points`),
  so a waited batch still pays a WAL flush per op. The barrier, a delete of a
  key no point has over the same ids, reaches every shard holding them after
  the batch (each shard applies its queue in order), so once it is applied
  the whole batch is too, and flushed. Verified on 1.19.2 with 3 shards.
  """
  # Never written, so the barrier delete changes nothing.
  @barrier_key "__engram_write_barrier"

  def set_payloads(col \\ nil, pairs)
  def set_payloads(_col, []), do: :ok

  def set_payloads(col, pairs) when is_list(pairs) do
    col = col || collection()
    ops = for {id, payload} <- pairs, do: %{set_payload: %{points: [id], payload: payload}}
    batch = [json: %{operations: ops}, params: [wait: false]] ++ req_opts()
    barrier = write_opts(%{keys: [@barrier_key], points: Enum.map(pairs, &elem(&1, 0))})

    instrument(:set_payload, fn ->
      with :ok <-
             batch_accepted(Req.post("#{base_url()}/collections/#{col}/points/batch", batch)),
           :ok <- write(&Req.post/2, "/collections/#{col}/points/payload/delete", barrier) do
        verify_applied(col, pairs)
      end
    end)
  end

  # Every op of the unwaited batch must be accepted ("acknowledged", or
  # "completed" if it applied first); anything else fails the page.
  defp batch_accepted({:ok, %{status: 200, body: %{"result" => results}}})
       when is_list(results) do
    case Enum.reject(
           results,
           &match?(%{"status" => s} when s in ["acknowledged", "completed"], &1)
         ) do
      [] -> :ok
      bad -> {:error, {:batch_op_failed, Enum.map(bad, & &1["status"])}}
    end
  end

  defp batch_accepted({:ok, %{status: status, body: body}}), do: write_error(status, body)
  defp batch_accepted({:error, reason}), do: {:error, reason}

  # The barrier proves the batch was applied in order and flushed, but not
  # that each op succeeded at apply time (a waited per-op write reported
  # that). So read the page back and compare: a payload that did not land
  # fails the page, and the caller retries it (re-review N4). One retrieve
  # of the set keys only, no vectors.
  defp verify_applied(col, pairs) do
    want = Map.new(pairs, fn {id, payload} -> {id, Jason.decode!(Jason.encode!(payload))} end)
    keys = want |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
    opts = [json: %{ids: Map.keys(want), with_payload: keys, with_vector: false}] ++ req_opts()

    case Req.post("#{base_url()}/collections/#{col}/points", opts) do
      {:ok, %{status: 200, body: %{"result" => points}}} when is_list(points) ->
        stored = Map.new(points, &{&1["id"], &1["payload"] || %{}})

        case for({id, _payload} <- pairs, not landed?(stored[id], want[id]), do: id) do
          [] -> :ok
          missing -> {:error, {:set_payloads_not_applied, missing}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp landed?(nil, _want), do: false
  defp landed?(stored, want), do: Enum.all?(want, fn {k, v} -> stored[k] == v end)

  defp write(request, path, opts) do
    case request.("#{base_url()}#{path}", opts) do
      {:ok, %{status: 200, body: body}} -> applied(body)
      {:ok, %{status: status, body: body}} -> write_error(status, body)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Patch (overwrite-or-add) payload keys on EVERY point matching the
  `{user_id, vault_id, path_hmac}` filter — vectors untouched. The cost-free
  way to re-path a note's points after a rename without re-running the
  embedder (#746). Triple-scope is mandatory: filtering on `path_hmac` alone
  could cross tenants if two users' folded HMACs collide.
  """
  #
  # `payload` uses the legacy string keys (`"path_hmac"`, `"folder_hmac"`,
  # base64). Each
  # format gets its own keys, so a v3 point never gains `p` and a v5 point never
  # gains a 44-byte `path_hmac`: one PATCH on the legacy points (while
  # `:legacy_filter_fields` is on) and one on the v5 points. A nil value on a v5
  # point deletes the key (no nulls in a v5 payload).
  def set_payload_by_filter(col \\ nil, user_id, vault_id, path_hmac, payload)
      when is_map(payload) do
    col = col || collection()

    legacy =
      if legacy_filter_fields?() or not v5_payload_format?(),
        do: [{legacy_note_filter(user_id, vault_id, path_hmac), payload, []}],
        else: []

    v5 =
      case v5_payload_format?() && hmac_id(path_hmac) do
        v when v in [nil, false] ->
          []

        old_id ->
          {set, unset} = v5_repath_payload(payload)
          filter = %{must: v5_conditions(user_id, vault_id) ++ [v5_eq(:path_id, old_id)]}
          [{filter, set, unset}]
      end

    Enum.reduce_while(legacy ++ v5, :ok, fn {filter, set, unset}, :ok ->
      # Delete first: the set rewrites `p`, after which the old-path filter
      # matches nothing.
      with :ok <- delete_payload_keys(col, filter, unset),
           :ok <- post_payload(col, filter, set) do
        {:cont, :ok}
      else
        err -> {:halt, err}
      end
    end)
  end

  defp v5_repath_payload(payload) do
    pairs =
      for {legacy, short} <- [{"path_hmac", :path_id}, {"folder_hmac", :folder_id}],
          Map.has_key?(payload, legacy),
          do: {PayloadKeys.short(short), hmac_id(payload[legacy])}

    {for({k, v} <- pairs, v != nil, into: %{}, do: {k, v}), for({k, nil} <- pairs, do: k)}
  end

  defp delete_payload_keys(_col, _filter, []), do: :ok

  defp delete_payload_keys(col, filter, keys) do
    opts = write_opts(%{filter: filter, keys: keys})

    instrument(:set_payload, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/payload/delete", opts) do
        {:ok, %{status: 200, body: body}} -> applied(body)
        {:ok, %{status: status, body: body}} -> write_error(status, body)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp post_payload(col, filter, payload) do
    opts = write_opts(%{filter: filter, payload: payload})

    instrument(:set_payload, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/payload", opts) do
        {:ok, %{status: 200, body: body}} -> applied(body)
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
        {:ok, %{status: 200, body: body}} -> applied(body)
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
        {:ok, %{status: 200, body: body}} -> applied(body)
        {:ok, %{status: 404}} -> :ok
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
  def delete_by_note(col \\ nil, user_id, vault_id, path_hmac),
    do: delete_by_note_except(col, user_id, vault_id, path_hmac, [])

  @doc """
  `delete_by_note/4`, keeping the points in `keep_ids`.
  """
  def delete_by_note_except(col, user_id, vault_id, path_hmac, keep_ids) do
    col = col || collection()

    filter = note_filter(user_id, vault_id, path_hmac)

    filter =
      if keep_ids == [], do: filter, else: Map.put(filter, :must_not, [%{has_id: keep_ids}])

    opts = write_opts(%{filter: filter})

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
        # Missing collection: nothing to delete. See `delete_points/2`.
        {:ok, %{status: 200, body: body}} -> applied(body)
        {:ok, %{status: 404}} -> :ok
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

    filter = note_filter(user_id, vault_id, path_hmac)

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

    filter = %{must: [match_filter(:user, user_id)]}
    opts = write_opts(%{filter: filter}, purpose)

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
        # Missing collection: nothing to delete. See `delete_points/2`.
        {:ok, %{status: 200, body: body}} -> applied(body)
        {:ok, %{status: 404}} -> :ok
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

    filter = %{must: [match_filter(:user, user_id), match_filter(:vault, vault_id)]}

    opts = write_opts(%{filter: filter})

    instrument(:delete, fn ->
      case Req.post("#{base_url()}/collections/#{col}/points/delete", opts) do
        # Missing collection: nothing to delete. See `delete_points/2`.
        {:ok, %{status: 200, body: body}} -> applied(body)
        {:ok, %{status: 404}} -> :ok
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
    * `:with_payload` — a list of the keys the caller reads, or `false`
      (default). Never `true` (Task 15.7).
    * `:with_vector` — defaults to `false`

  Returns `{:ok, %{points: [...], next_page_offset: term() | nil}} | {:error, term()}`.
  """
  def scroll(col \\ nil, opts) when is_list(opts) do
    collection_name = col || collection()
    url = "#{base_url()}/collections/#{collection_name}/points/scroll"
    limit = Keyword.get(opts, :limit, 200)

    # Above max_page/0 the Cloud strict limit refuses the page; fail here,
    # where the bad caller is in the stacktrace.
    if limit > @max_page,
      do: raise(ArgumentError, "scroll limit #{limit} is over max_page #{@max_page}")

    body = %{
      filter: Keyword.fetch!(opts, :filter),
      with_payload: Keyword.get(opts, :with_payload, false),
      with_vector: Keyword.get(opts, :with_vector, false),
      limit: limit
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
      with_payload: result_payload_for(search_opts)
    }

    case quantization_params(search_opts) do
      nil -> base
      params -> Map.put(base, :params, params)
    end
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

  # -- Dual-format filters (Task 15.4) -----------------------------------
  #
  # During the v5 pass a vault holds v3/v4 points (long `*_hmac` keys, base64
  # HMACs, dashed uuids) and v5 points (short `PayloadKeys` keys, 128-bit hex
  # ids). Every filter condition goes through `match_filter/2` or
  # `range_filter/2`. With `:v5_payload_format` on, they match EITHER format
  # with a `should` while `:legacy_filter_fields` is on (the default), and
  # only the v5 format once
  # the pass has dropped the legacy fields (Task 18.1). A `should` nested in a
  # `must` is still an AND with the other conditions, so tenant scoping is
  # unchanged.

  @legacy_keys %{
    user: "user_id",
    vault: "vault_id",
    path: "path_hmac",
    folder: "folder_hmac",
    type: "type_hmac",
    tags: "tags_hmac"
  }
  @v5_keys %{
    user: :user_id,
    vault: :vault_id,
    path: :path_id,
    folder: :folder_id,
    type: :type_id,
    tags: :tags_id
  }
  @range_keys %{fm_timestamp: :fm_timestamp, fm_created: :fm_created}

  # OFF until flipped in code, before any v5 write (PR-17 also flips
  # `:write_v5_layout`; the two go together or v5 points are unfindable).
  # While off, nothing about Qdrant changes: no v5 indexes, legacy-only
  # filters. It gates the indexes because their disk footprint is unmeasured:
  # 20 more payload indexes per collection SIGBUSed CI's 2 GB tmpfs Qdrant,
  # and prod's disk is tight. Measure on dev 1.19.2, then flip the default.
  @doc """
  Whether the v5 payload format is on (see the comment above). Writing the v5
  layout IMPLIES it: a v5 point only carries short keys, so writing one with
  legacy-only filters would make it unfindable. One accessor, so the two
  flags cannot disagree and no operator has to set both.
  """
  @spec v5_payload_format?() :: boolean()
  def v5_payload_format?,
    do: ServiceConfig.get(:v5_payload_format, false) == true or write_v5_layout?()

  @doc "Whether new points are written in the v5 layout (UUIDv5 ids, v5 payload)."
  @spec write_v5_layout?() :: boolean()
  def write_v5_layout?, do: ServiceConfig.get(:write_v5_layout, false) == true
  defp legacy_filter_fields?, do: ServiceConfig.get(:legacy_filter_fields, true)

  @doc """
  One filter condition for `field` equal to `value` (a list matches any), in
  both payload formats. `:user`/`:vault` take ids as stored in Postgres;
  `:path`/`:folder`/`:type`/`:tags` take the base64 HMACs the legacy filters
  use.
  """
  @spec match_filter(:user | :vault | :path | :folder | :type | :tags, term()) :: map()
  def match_filter(field, value) do
    legacy = %{key: Map.fetch!(@legacy_keys, field), match: match(value)}

    case v5_payload_format?() && v5_value(field, value) do
      v when v in [nil, false] ->
        legacy

      v ->
        v5 = %{key: PayloadKeys.short(Map.fetch!(@v5_keys, field)), match: match(v)}
        if legacy_filter_fields?(), do: %{should: [legacy, v5]}, else: v5
    end
  end

  @doc "A range condition on `fm_timestamp` / `fm_created`, in both formats."
  @spec range_filter(:fm_timestamp | :fm_created, map()) :: map()
  def range_filter(field, range) do
    legacy = %{key: Atom.to_string(field), range: range}
    v5 = %{key: PayloadKeys.short(Map.fetch!(@range_keys, field)), range: range}

    cond do
      not v5_payload_format?() -> legacy
      legacy_filter_fields?() -> %{should: [legacy, v5]}
      true -> v5
    end
  end

  @doc """
  Nested filter on a user-added frontmatter key: the note has an `fm_attrs`
  (`fa`) entry whose key id is `key_id` AND whose value matches, in the SAME
  element (so `a: 1, b: 5` never matches `a = 5`). `value` is
  `{:h, id | [ids]}` (exact: a value filter id, or any of several) or
  `{:n | :d, range}` (`gte`/`gt`/`lte`/`lt`; numbers, or dates in unix
  seconds).
  """
  @spec attr_filter(integer(), {:h, String.t() | [String.t()]} | {:n | :d, keyword() | map()}) ::
          map()
  def attr_filter(key_id, {:h, ids}), do: nested_attr(key_id, %{key: "h", match: match(ids)})

  def attr_filter(key_id, {field, range}) when field in [:n, :d],
    do: nested_attr(key_id, %{key: Atom.to_string(field), range: Map.new(range)})

  defp nested_attr(key_id, condition) do
    %{
      nested: %{
        key: PayloadKeys.short(:fm_attrs),
        filter: %{must: [%{key: "k", match: %{value: key_id}}, condition]}
      }
    }
  end

  defp match(values) when is_list(values), do: %{any: values}
  defp match(value), do: %{value: value}

  defp v5_value(field, ids) when field in [:user, :vault] and is_list(ids),
    do: Enum.map(ids, &FilterId.uuid(to_string(&1)))

  defp v5_value(field, id) when field in [:user, :vault], do: FilterId.uuid(to_string(id))

  defp v5_value(_field, b64s) when is_list(b64s) do
    case Enum.map(b64s, &hmac_id/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      ids -> ids
    end
  end

  defp v5_value(_field, b64), do: hmac_id(b64)

  # A legacy filter value that is not a full base64 HMAC (a test literal, a
  # malformed opt) has no v5 form; the legacy condition alone then applies.
  defp hmac_id(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, <<_::binary-size(16), _::binary>> = hmac} -> FilterId.from_hmac(hmac)
      _ -> nil
    end
  end

  defp hmac_id(_), do: nil

  defp legacy_note_filter(user_id, vault_id, path_hmac) do
    %{
      must: [
        %{key: "user_id", match: %{value: user_id}},
        %{key: "vault_id", match: %{value: vault_id}},
        %{key: "path_hmac", match: %{value: path_hmac}}
      ]
    }
  end

  defp v5_conditions(user_id, vault_id),
    do: [v5_eq(:user_id, FilterId.uuid(user_id)), v5_eq(:vault_id, FilterId.uuid(vault_id))]

  defp v5_eq(name, value), do: %{key: PayloadKeys.short(name), match: %{value: value}}

  defp note_filter(user_id, vault_id, path_hmac) do
    %{
      must: [
        match_filter(:user, user_id),
        match_filter(:vault, vault_id),
        match_filter(:path, path_hmac)
      ]
    }
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

    must = [match_filter(:user, user_id)]
    # `vault_id` accepts one id or a set. The set form is what a multi-vault
    # OAuth grant (and a subset-restricted API key) needs: without it the only
    # options were one query per vault or dropping the filter entirely, and
    # dropping it leaks every vault the credential was scoped away from (#729).
    # `vault_id` is already a payload index (`QdrantLayout.payload_indexes/2`), so
    # `any` needs no new index — same shape as tags_hmac below.
    must =
      case vault_id do
        nil -> must
        id when is_binary(id) -> must ++ [match_filter(:vault, id)]
        ids when is_list(ids) -> must ++ [match_filter(:vault, ids)]
      end

    must = if tags_hmac, do: [match_filter(:tags, tags_hmac) | must], else: must
    must = if folder_hmac, do: [match_filter(:folder, folder_hmac) | must], else: must
    must = if type_hmac, do: [match_filter(:type, type_hmac) | must], else: must

    must
    |> add_range_clause(:fm_timestamp, search_opts, :fm_timestamp_gte, :fm_timestamp_lte)
    |> add_range_clause(:fm_created, search_opts, :fm_created_gte, :fm_created_lte)
    # User-added frontmatter key filters, already resolved to nested
    # conditions (`Engram.Search.FieldFilters`).
    |> Kernel.++(Keyword.get(search_opts, :attr_filters, []))
    |> then(&%{must: &1})
  end

  defp add_range_clause(must, key, opts, gte_key, lte_key) do
    range =
      %{}
      |> maybe_put_bound(:gte, Keyword.get(opts, gte_key))
      |> maybe_put_bound(:lte, Keyword.get(opts, lte_key))

    if range == %{}, do: must, else: must ++ [range_filter(key, range)]
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
      with_payload: result_payload_for(search_opts)
    }
  end

  # Qdrant's own RRF default, kept so fused scores read as before.
  @rrf_k 2

  @doc """
  Hybrid search: the dense and keyword legs run as one `/points/query/batch`
  request and are fused here by `Engram.Search.Fusion.rrf/2` (k = 2), so
  fused-score ties break the same way every time (server-side RRF orders
  them arbitrarily). `sparse` is `%{indices, values}`. Tenant filter is
  applied to BOTH legs (load-bearing: the sparse inverted index is global).
  Each leg fetches `:limit` ids and scores only; the fused `:limit` points
  then come back in one retrieve with the payload fields results use, or
  with none and no retrieve at all when search reads them from Postgres
  (`:chunk_text_read`). No vectors: MMR fetches its pool's (`retrieve/3`).
  The legs carrying payload and vectors returned up to 2x the bytes for
  points fusion drops.
  """
  def hybrid_search(col \\ nil, dense, sparse, search_opts) do
    col = col || collection()
    limit = Keyword.get(search_opts, :limit, 5)

    instrument(:hybrid_search, fn ->
      opts = [json: hybrid_search_body(dense, sparse, search_opts)] ++ req_opts(:search)

      with {:ok, legs} <- do_query(col, "/points/query/batch", opts, &batch_results/1),
           fused =
             legs
             |> Enum.map(fn leg -> Enum.map(leg, &%{id: &1.qdrant_id, score: &1.score}) end)
             |> Fusion.rrf(@rrf_k)
             |> Enum.take(limit),
           {:ok, points} <- fused_points(col, Enum.map(fused, & &1.id), search_opts) do
        by_id = Map.new(points, &{&1.qdrant_id, &1})

        # A point deleted between the legs and the retrieve is dropped.
        {:ok, for(%{id: id, score: score} <- fused, p = by_id[id], do: Map.put(p, :score, score))}
      end
    end)
  end

  # The payload keys `search_results/1` reads for a hit's text and display
  # fields (Task 15.7). `u` only marks a v5 point (its AAD is implied bound),
  # so it is asked for only with the v5 format on.
  @text_payload ~w(text title heading_path source_path tags text_nonce
                   title_nonce heading_path_nonce aad_version)

  @doc """
  THE payload include list of every search path (Task 15.8), by where the
  hits' text is read from:

    * `:payload` (`:chunk_text_read` off): the text keys and `vault_id`.
    * `:postgres` (`:chunk_text_read` on): nothing. The chunk row holds the
      text, heading and vault, and the note row the display fields.
    * `:fallback`: the text keys, for the hits whose chunk row has no text
      (rows written before the text columns); the row gives the vault.

  Never `true`.
  """
  @spec result_payload(:payload | :postgres | :fallback) :: [String.t()] | false
  def result_payload(:payload), do: ["vault_id" | result_payload(:fallback)]
  def result_payload(:postgres), do: false

  def result_payload(:fallback),
    do: if(v5_payload_format?(), do: @text_payload ++ ["u"], else: @text_payload)

  # `:chunk_text_read` comes from the caller's search opts, read ONCE per
  # request by `Engram.Search`, so the keys asked for here and how search
  # reads the hits never disagree mid-flip.
  defp result_payload_for(search_opts),
    do:
      result_payload(
        if Keyword.get(search_opts, :chunk_text_read, false), do: :postgres, else: :payload
      )

  # With nothing to fetch, the fused ids are the result: a point deleted
  # since the legs has no chunk row either, and search drops it there.
  defp fused_points(col, ids, search_opts) do
    case result_payload_for(search_opts) do
      false -> {:ok, Enum.map(ids, &%{qdrant_id: &1})}
      keys -> do_retrieve(col, ids, with_payload: keys)
    end
  end

  @doc """
  The given points, as search results without scores: `:with_payload` an
  include list (default `false`), `:with_vector` true for the dense vector
  (MMR's pool, Task 15.8). A missing point is left out.
  """
  @spec retrieve(String.t() | nil, [String.t()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def retrieve(col \\ nil, ids, opts),
    do: instrument(:retrieve, fn -> do_retrieve(col || collection(), ids, opts) end)

  defp do_retrieve(_col, [], _opts), do: {:ok, []}

  defp do_retrieve(col, ids, opts) do
    body = %{ids: ids, with_payload: Keyword.get(opts, :with_payload, false)}

    body =
      if Keyword.get(opts, :with_vector, false),
        do: Map.put(body, :with_vector, ["dense"]),
        else: body

    do_query(col, "/points", [json: body] ++ req_opts(:search), &{:ok, search_results(&1)})
  end

  @doc false
  def hybrid_search_body(dense, sparse, search_opts) do
    filter = build_tenant_filter(search_opts)
    limit = Keyword.get(search_opts, :limit, 5)

    dense_leg =
      %{query: dense, using: "dense", filter: filter, limit: limit, with_payload: false}
      |> then(fn leg ->
        case quantization_params(search_opts) do
          nil -> leg
          params -> Map.put(leg, :params, params)
        end
      end)

    sparse_leg = %{
      query: %{indices: sparse.indices, values: sparse.values},
      using: "keyword",
      filter: filter,
      limit: limit,
      with_payload: false
    }

    %{searches: [dense_leg, sparse_leg]}
  end

  @doc """
  The ids among `point_ids` whose points hold a `dense` vector. A recommend
  positive without one is refused for the whole request, and sparse-only
  points (frontmatter, data, canvas, base) are normal. One page per
  `max_ids/0` ids: the `has_id` filter caps each page's matches at its batch.
  """
  def dense_point_ids(col \\ nil, point_ids)
  def dense_point_ids(_col, []), do: {:ok, []}

  def dense_point_ids(col, point_ids) do
    point_ids
    |> Enum.chunk_every(@max_ids)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      filter = %{must: [%{has_id: batch}, %{has_vector: "dense"}]}

      case scroll(col, filter: filter, with_payload: false, limit: length(batch)) do
        {:ok, %{points: points}} -> {:cont, {:ok, [Enum.map(points, & &1["id"]) | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, pages |> Enum.reverse() |> Enum.concat()}
      error -> error
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
      filter: Map.put(build_tenant_filter(search_opts), :must_not, has_ids(point_ids)),
      limit: Keyword.get(search_opts, :limit, 5),
      with_payload: result_payload_for(search_opts)
    }
    |> then(fn b ->
      case quantization_params(search_opts) do
        nil -> b
        params -> Map.put(b, :params, params)
      end
    end)
  end

  # One `has_id` per `max_ids/0` ids: `not A and not B` is `not (A or B)`, and
  # each condition stays under the Cloud `condition_max_size`.
  # ponytail: a note past ~110k points (64 filter conditions) still trips
  # `filter_max_conditions`; average a sample of its points if one appears.
  defp has_ids(point_ids),
    do: point_ids |> Enum.chunk_every(@max_ids) |> Enum.map(&%{has_id: &1})

  # Any of the ids (`should` is OR), for a write that must skip missing ones.
  defp ids_filter(point_ids), do: %{should: has_ids(point_ids)}

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
        aad_version: Map.get(payload, "aad_version"),
        format: if(Map.has_key?(payload, PayloadKeys.short(:user_id)), do: :v5)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end)
  end
end
