defmodule Engram.Vector.QdrantLayout do
  @moduledoc """
  Desired storage + safety params for the EXISTING Qdrant collection, and the
  diff against what `GET /collections/{name}` reports. No HTTP.

  Measured on prod 2026-10-18 (Qdrant Cloud 1.18.2, 447k points): the sparse
  `keyword` index (419 MB) and payload indexes (~140 MB) are the bulk of RAM;
  dense storage is already mmap'd. So this moves the sparse index and dense
  vectors on disk, serialises optimizer rebuilds onto one thread, and turns on
  strict-mode upsert guards for memory and disk.

  On Qdrant >= 1.19.2 (`tenant_layout?/1`, Task 8.1) `u` is the `is_tenant`
  index, every other payload index sets `enable_hnsw: false`, every payload
  index is on disk, and a new collection caps its segments (create-time
  only, `@max_segment_size_kb`). The per-tenant graph (`m: 0`,
  `payload_m: 16`, one graph per `u` value) waits for `tenant_graph?/3`
  (legacy filters off): while legacy `user_id` points and v5 `u` points
  coexist, m 0 would split one user into two disconnected subgraphs. Below 1.19.2 (prod's old 1.18.2
  cluster, self-host compose) the layout is exactly the pre-8.1 one, so the
  reconcile never PATCHes those collections for it.

  Field names are the PATCH (`UpdateCollection`) names. The GET response names
  two of them differently (`optimizers_config` reads back as
  `optimizer_config`, vectors live under `params`), which `diff/2` maps.
  Every PATCH sub-object is merged into the current config by Qdrant
  (`update_collection` in `toc/collection_meta_ops.rs`), not replaced, so a
  partial body never resets an unrelated setting.
  """

  alias Engram.ServiceConfig
  alias Engram.Vector.PayloadKeys

  # Strict-mode fields by the Qdrant versions that honour them, `since <= v <
  # until`, from each tag's docs/redoc/master/openapi.json `StrictModeConfig`:
  #   * memory: added 1.18.1; 1.19.0 marks it "Deprecated: use the node-wide
  #     quota config (`PUT /quotas`) ... Scheduled for removal in 1.21."
  #   * disk: added 1.18.2 (still in 1.18.3); GONE from 1.19.0, moved to the
  #     node-wide `/quotas`. 1.19 answers a PATCH carrying it with 200 and
  #     drops it, so sending it there never converges.
  # Outside its range a field is never sent, so `diff/2` never compares it.
  # CI pins 1.17.1, which has neither; self-host compose pins 1.18.3 (both).
  #
  # From 1.19.0 both guards also live in the node-wide `PUT /quotas`
  # (`QuotaConfig`, openapi v1.19.2), see `desired_quotas/2`. The strict
  # memory field stays sent until 1.21 at the SAME percent, so a server whose
  # quotas are unmanaged keeps a heap guard and a stored 1.18 value never goes
  # stale.
  @strict_guards [
    {"max_resident_memory_percent", :heap, "1.18.1", "1.21.0"},
    {"max_disk_usage_percent", :disk, "1.18.2", "1.19.0"}
  ]

  @quota_fields [disk: "max_disk_usage_percent", heap: "max_resident_memory_percent"]

  @default_limits %{disk: %{percent: 85, reserve: nil}, heap: %{percent: 85, reserve: nil}}
  @off_limits %{disk: %{percent: 100, reserve: nil}, heap: %{percent: 100, reserve: nil}}

  @gib 1024 * 1024 * 1024
  @min_memory_reserve 256 * 1024 * 1024

  @storage %{
    "vectors" => %{"dense" => %{"on_disk" => true}},
    "sparse_vectors" => %{"keyword" => %{"modifier" => "idf", "index" => %{"on_disk" => true}}},
    "optimizers_config" => %{"max_optimization_threads" => 1}
  }

  # Task 8.1, Qdrant >= 1.19.2.
  @tenant_version "1.19.2"
  @tenant_hnsw %{"m" => 0, "payload_m" => 16, "max_indexing_threads" => 1}

  # KB of the segment's largest vector storage (Qdrant 1.19.2
  # `max_available_vectors_size_in_bytes`): ~2 KB a point for dense f16 1024,
  # so ~64k points. A segment build holds its whole sparse inverted index in
  # RAM (12 B per non-zero, ~526 a point), ~13 KB a point all in, so the
  # worst merge is ~1 GB: room on a 4 GiB node (mx1). It also caps each
  # appendable segment, whose sparse index stays in RAM until indexed, at
  # ~170 MB. Half Qdrant's own default for one indexing thread (256,000).
  #
  # CREATE-TIME ONLY: `storage/2` (the reconcile) never sends it. Collections
  # created at 1,000,000 (prod v2, the revert target) keep their value. A
  # lower cap does not rebuild anything (no optimizer splits a segment), but
  # the serving cluster is not where to find out.
  @max_segment_size_kb 128_000

  # Payload fields every tenant-scoped op filters on. Qdrant Cloud strict-mode
  # rejects (400) a filter on an un-indexed field, so each must have an index
  # before any upsert/search/delete (#626). `type_hmac` is the OKF frontmatter
  # `type` blind index (spec 2026-07-02); `folder_hmac`/`tags_hmac` are the
  # folder and tag search filters (#1609). These are the legacy (v3/v4) names,
  # indexed only while `:legacy_filter_fields` is on (a collection that may
  # still hold v3/v4 points); the v5 short-key indexes come from
  # `PayloadKeys.index_fields/0`.
  @legacy_keyword ~w(user_id vault_id path_hmac type_hmac folder_hmac tags_hmac)
  # OKF frontmatter dates, plaintext so Qdrant can range-filter on them.
  @legacy_integer ~w(fm_timestamp fm_created)
  # The tenant field of each format. Legacy `user_id` gets no `is_tenant`
  # (one tenant field per collection), but keeps `enable_hnsw` so copied
  # v3/v4 points still have a per-user graph while the pass runs.
  @tenant_field "u"
  @legacy_tenant_field "user_id"

  # PATCH key -> path of the same settings in the GET `config` object.
  @get_path %{
    "hnsw_config" => ["hnsw_config"],
    "vectors" => ["params", "vectors"],
    "sparse_vectors" => ["params", "sparse_vectors"],
    "optimizers_config" => ["optimizer_config"],
    "strict_mode_config" => ["strict_mode_config"]
  }

  # Hard limits on Qdrant Cloud: circuit breakers against code bugs and
  # runaway sweeps (10-19 config audit #7, docs sweep #15). Each sits at 2x
  # the largest request the app sends, as `Qdrant` declares it: a 4096-id
  # scroll page (`max_page/0`, OrphanSweep; Qdrant applies `max_query_limit`
  # to scroll too), a 2048-id `has_id` (`max_ids/0`), a 64-point write batch
  # (`max_write_batch/0`), a hybrid batch of 2. qdrant_strict_callers_test
  # pins it. `search_allow_exact` stays allowed (sweep #19): the
  # ANN-recall check compares against `params.exact: true`, and
  # max_query_limit plus max_timeout already bound an exact search. No
  # read/write_rate_limit: they are per replica, not per tenant, so one large
  # vault would throttle everyone.
  @max_timeout_s 30

  @hard_limits %{
    "max_query_limit" => 8192,
    "search_max_oversampling" => 4,
    "search_max_hnsw_ef" => 512,
    "upsert_max_batchsize" => 256,
    "filter_max_conditions" => 64,
    "condition_max_size" => 4096,
    "max_points_count" => 1_500_000,
    "max_timeout" => @max_timeout_s,
    "search_max_batchsize" => 8
  }

  # No byte breakers (`max_collection_{payload,vector}_size_bytes`): a static
  # number measured on one layout drifts as the layout changes (f16 dense,
  # chunk text moving to Postgres), and Qdrant checks it against a size
  # estimate refreshed only every 32 requests. The disk and memory guards
  # (`max_disk_usage_percent` in /quotas, `max_resident_memory_percent`)
  # already refuse writes on LIVE usage, which is what a byte cap stands in for.

  # Kill switch values: no request reaches them. A null cannot clear a strict
  # field (see `desired/4`), so the switch raises each one instead. The byte
  # fields are included in case an earlier config or a hand PATCH set them.
  @ceiling 2_147_483_647
  @byte_ceiling 2 ** 53 - 1
  @lifted_limits Map.merge(
                   Map.new(@hard_limits, fn {field, _} -> {field, @ceiling} end),
                   %{
                     "max_collection_payload_size_bytes" => @byte_ceiling,
                     "max_collection_vector_size_bytes" => @byte_ceiling
                   }
                 )

  @doc "Cloud `max_timeout`, seconds: every server `timeout` the app sends is at most this."
  def max_timeout_s, do: @max_timeout_s

  @doc """
  The strict-mode hard limits for a deployment. `:cloud` (our Qdrant Cloud
  prod) gets the circuit breakers. `:self_host` gets none: a self-hoster's
  collection can outgrow any number picked from our prod.
  """
  # No @spec: both clauses return literals, so dialyzer's :underspecs flags
  # any wider map type.
  def desired_strict(:self_host), do: %{}
  def desired_strict(:cloud), do: @hard_limits

  # Qdrant Cloud's managed default, set here too so the cloud profile
  # (`QDRANT_STRICT_PROFILE=cloud` on staging) refuses an unindexed filtered
  # read as prod does (#2138). Prod already has it, so no PATCH moves it.
  # Not `unindexed_filtering_update`: prod leaves it unset, and setting it
  # would refuse update-by-filter on unindexed keys there.
  @unindexed_refused %{"unindexed_filtering_retrieve" => false}

  @doc """
  The strict fields refusing unindexed filters on `deployment`. Applied by
  the boot reconcile only, after the payload indexes; the poller leaves them.
  """
  def unindexed_refused(:self_host), do: %{}
  def unindexed_refused(:cloud), do: @unindexed_refused

  @doc """
  The desired PATCH sub-objects for a server at `version` (`nil` = unknown),
  with strict mode refusing writes at `limits` (see `strict_limits/2`;
  default 85/85), or switched off when `strict?` is false.
  Strict mode is included only with at least one guard the server supports:
  enabling it with no guard adds risk for no protection. On `:cloud` it also
  carries `desired_strict/1`, which the kill switch lifts to a ceiling.
  """
  @spec desired(Version.t() | nil, map() | nil, boolean(), :cloud | :self_host, boolean()) ::
          map()
  def desired(
        version,
        limits \\ @default_limits,
        strict? \\ true,
        deployment \\ :self_host,
        tenant_graph? \\ false
      )

  # Ops kill switch (QDRANT_STRICT_MODE=false): our two guards at 100 (a
  # refusal only on a full disk/heap), never `enabled: false`, which would also
  # drop Qdrant Cloud's own strict-mode guards (unindexed filtering). 100, not
  # null: the strict-mode PATCH merge keeps the old value for a null field
  # (`x.or(self.x)` in lib/collection/src/operations/config_diff.rs, 1.18.2).
  def desired(version, _limits, false, deployment, graph?) do
    case supported_guards(version, @off_limits) do
      [] ->
        storage(version, graph?)

      guards ->
        Map.put(
          storage(version, graph?),
          "strict_mode_config",
          Map.merge(lifted(deployment), Map.new(guards))
        )
    end
  end

  def desired(version, limits, true, deployment, graph?) do
    case supported_guards(version, limits || @default_limits) do
      [] ->
        storage(version, graph?)

      guards ->
        strict =
          deployment
          |> desired_strict()
          |> Map.merge(unindexed_refused(deployment))
          |> Map.merge(Map.new([{"enabled", true} | guards]))

        Map.put(storage(version, graph?), "strict_mode_config", strict)
    end
  end

  @doc "True on Qdrant >= 1.19.2, where the tenant layout applies (Task 8.1); false when unknown."
  @spec tenant_layout?(Version.t() | nil) :: boolean()
  def tenant_layout?(nil), do: false
  def tenant_layout?(version), do: Version.compare(version, @tenant_version) != :lt

  @doc """
  True when the collection may drop its global graph for the per-tenant one
  (`m: 0`): `switch?` (legacy filters off, so no legacy `user_id` point is
  left), a 1.19.2+
  server, and `info` (a GET `result`) proving `u` is the `is_tenant` index,
  i.e. the collection was created with the tenant layout. Version alone is
  not enough: an older collection on a 1.19.2 server has bare indexes, and m 0
  would build an extra graph per value of every one of them.
  """
  @spec tenant_graph?(map() | nil, Version.t() | nil, boolean()) :: boolean()
  def tenant_graph?(info, version, switch?) do
    switch? and tenant_layout?(version) and
      get_in(info || %{}, ["payload_schema", @tenant_field, "params", "is_tenant"]) == true
  end

  defp storage(version, graph?) do
    if tenant_layout?(version) do
      @storage
      |> then(&if graph?, do: Map.put(&1, "hnsw_config", @tenant_hnsw), else: &1)
      # A float, as Qdrant echoes it: an integer config (1) would read back
      # 1.0 and drift every boot.
      |> put_in(
        ["optimizers_config", "deleted_threshold"],
        ServiceConfig.get(:qdrant_deleted_threshold, 0.2) / 1
      )
    else
      @storage
    end
  end

  @doc """
  The payload indexes to create, `[{field, schema}]`, for a server at
  `version`: the v5 short-key set (`PayloadKeys.index_fields/0`), plus the
  legacy set while `legacy?` (`:legacy_filter_fields`) is on. Below 1.19.2
  the schemas are bare `"keyword"` / `"integer"`. On 1.19.2 every index is on
  disk, `u` is the tenant field, and only the two tenant fields build HNSW
  edges.

  With `legacy?` off every filter is v5-only (`Qdrant.match_filter/2`), so no
  legacy index is listed and a new collection never builds one. An existing
  index is left alone: boot only creates missing indexes, it never deletes
  one (so an old collection keeps a `note_id` index nothing reads).
  """
  @spec payload_indexes(Version.t() | nil, boolean()) :: [{String.t(), String.t() | map()}]
  def payload_indexes(version, legacy?) do
    legacy =
      if legacy?,
        do:
          Enum.map(@legacy_keyword, &{&1, "keyword"}) ++
            Enum.map(@legacy_integer, &{&1, "integer"}),
        else: []

    indexes = legacy ++ PayloadKeys.index_fields()

    if tenant_layout?(version), do: Enum.map(indexes, &tenant_schema/1), else: indexes
  end

  # `on_disk` is deprecated from 1.19 in favour of `memory: "cold"` (same
  # effect, and 1.19.2 still echoes `on_disk`). Kept because 1.18 has no
  # `memory`; switch to `memory: "cold"` before 1.21 drops deprecated fields.
  defp tenant_schema({@legacy_tenant_field, "keyword"}),
    do: {@legacy_tenant_field, %{"type" => "keyword", "on_disk" => true}}

  defp tenant_schema({field, "keyword"}),
    do: {field, %{"type" => "keyword", "on_disk" => true, "enable_hnsw" => false}}

  defp tenant_schema({field, "integer"}) do
    {field,
     %{
       "type" => "integer",
       "lookup" => false,
       "range" => true,
       "on_disk" => true,
       "enable_hnsw" => false
     }}
  end

  defp tenant_schema({@tenant_field, schema}),
    do: {@tenant_field, Map.put(schema, "is_tenant", true)}

  defp tenant_schema({field, schema}), do: {field, Map.put(schema, "enable_hnsw", false)}

  defp lifted(:cloud), do: @lifted_limits
  defp lifted(:self_host), do: %{}

  defp supported_guards(version, limits) do
    kinds = guard_kinds(version)

    for {field, kind, _since, _until} <- @strict_guards,
        kind in kinds,
        do: {field, limits[kind].percent}
  end

  @doc """
  The write limits Qdrant enforces, `%{kind => percent}`: the strict-mode
  ones in `config` (a GET `result.config`) for guards `version` honours (a
  1.19 server may keep a stored disk field it ignores), and on 1.19+ the
  node-wide `quotas` (a GET `/quotas` `result.config`). Where both cap a kind
  the lower one refuses first, so it wins. `%{}` when nothing is enforced.
  """
  @spec applied_limits(map() | nil, Version.t() | nil, map() | nil) ::
          %{optional(:heap | :disk) => integer()}
  def applied_limits(config, version, quotas \\ nil) do
    strict = (config || %{})["strict_mode_config"] || %{}
    kinds = guard_kinds(version)

    from_strict =
      for {field, kind, _since, _until} <- @strict_guards,
          strict["enabled"] == true,
          kind in kinds,
          is_integer(strict[field]),
          into: %{},
          do: {kind, strict[field]}

    Map.merge(from_strict, applied_quotas(quotas, version), fn _kind, a, b -> min(a, b) end)
  end

  defp applied_quotas(%{"enabled" => true} = quotas, version) do
    kinds = quota_kinds(version)

    for {kind, field} <- @quota_fields,
        kind in kinds,
        is_integer(quotas[field]),
        into: %{},
        do: {kind, quotas[field]}
  end

  defp applied_quotas(_quotas, _version), do: %{}

  @doc "The guards `version` can enforce through `/quotas` (Qdrant >= 1.19.0); `[]` when unknown."
  @spec quota_kinds(Version.t() | nil) :: [:heap | :disk]
  def quota_kinds(nil), do: []

  def quota_kinds(version),
    do: if(Version.compare(version, "1.19.0") == :lt, do: [], else: [:disk, :heap])

  @doc """
  The `PUT /quotas` body for `limits` (see `strict_limits/2`; default 85/85),
  or 100/100 when `strict?` is false (the same kill switch as strict mode).
  PUT replaces the whole config, so this is all of it; `release_margin_percent`
  is left unset, i.e. Qdrant's default (5).
  """
  @spec desired_quotas(map() | nil, boolean()) :: map()
  def desired_quotas(limits, strict?) do
    limits = if strict?, do: limits || @default_limits, else: @off_limits

    Map.new([
      {"enabled", true} | for({kind, field} <- @quota_fields, do: {field, limits[kind].percent})
    ])
  end

  @doc "True when the GET `/quotas` `config` does not already satisfy `desired`."
  @spec quotas_drift?(map() | nil, map()) :: boolean()
  def quotas_drift?(config, desired), do: not subset?(desired, config || %{})

  @doc "The strict-mode guards (`:heap`, `:disk`) `version` honours; `[]` when unknown."
  @spec guard_kinds(Version.t() | nil) :: [:heap | :disk]
  def guard_kinds(nil), do: []

  def guard_kinds(version) do
    for {_field, kind, since, until} <- @strict_guards,
        Version.compare(version, since) != :lt and Version.compare(version, until) == :lt,
        do: kind
  end

  @doc """
  Strict-mode refusal limits, in whole percent, from an absolute reserve so
  they scale with the cluster instead of sitting at a fixed 85:

    * disk: reserve `max(1 GiB, 2 x the largest single optimization)` of
      the volume's capacity. Qdrant starts an optimization (merge, vacuum,
      config-mismatch rebuild, one segment set at a time) only with 2x its
      input segments' disk size free (`check_segments_size`,
      lib/shard/src/optimize.rs), and no input set exceeds one capped
      segment, so the largest is `collection x min(segment_points, points) /
      points` (`segment_points/1`). With the cap or point count unknown it
      falls back to 0.35x the collection (the uncapped on-disk rewrite's
      measured 0.26x peak plus margin);
    * heap: reserve `max(256 MiB, opts.memory_reserve)` of the container
      memory limit (a rewrite's measured heap spike is ~0.25 GB).

  `/memory` disk_bytes is the logical size, above the block count Qdrant's
  check reads, so the disk estimate errs high. `floor(100 * (size -
  reserve) / size)`, clamped to 70..95. An unknown size keeps
  `opts.static`. Returns `%{disk: %{percent:, reserve:}, heap: ...}`
  (`reserve` nil when static).
  """
  @spec strict_limits(map(), map()) :: map()
  def strict_limits(%{capacity: cap, collection: coll, memory_limit: mem} = sizes, opts) do
    disk_reserve = disk_reserve(coll, sizes[:points], sizes[:segment_points])
    heap_reserve = max(@min_memory_reserve, opts.memory_reserve)

    %{
      disk: limit(cap, disk_reserve, opts.static.disk),
      heap: limit(mem, heap_reserve, opts.static.heap)
    }
  end

  defp limit(size, reserve, _static) when is_integer(size) and size > 0 and is_integer(reserve),
    do: %{percent: (100 * (size - reserve)) |> div(size) |> max(70) |> min(95), reserve: reserve}

  defp limit(_size, _reserve, static), do: %{percent: static, reserve: nil}

  defp disk_reserve(coll, points, seg)
       when is_integer(coll) and is_integer(points) and points > 0 and is_integer(seg),
       do: max(@gib, div(2 * coll * min(seg, points), points))

  defp disk_reserve(coll, _points, _seg) when is_integer(coll),
    do: max(@gib, div(coll * 35, 100))

  defp disk_reserve(_coll, _points, _seg), do: nil

  @doc """
  Points in one capped segment of the collection in `info` (a GET
  `/collections/{name}` result): `optimizer_config.max_segment_size` KB over
  the bytes of one `dense` vector (Qdrant caps a segment by its largest
  vector storage). nil when the cap is unset (Qdrant then picks one per CPU
  count) or the shape is unknown.
  """
  @spec segment_points(map() | nil) :: non_neg_integer() | nil
  def segment_points(%{"config" => config}) do
    kb = get_in(config, ["optimizer_config", "max_segment_size"])
    dense = get_in(config, ["params", "vectors", "dense"]) || %{}

    if is_integer(kb) and is_integer(dense["size"]) and dense["size"] > 0,
      do: div(kb * 1024, dense["size"] * vector_bytes(dense["datatype"]))
  end

  def segment_points(_info), do: nil

  defp vector_bytes("float16"), do: 2
  defp vector_bytes("uint8"), do: 1
  defp vector_bytes(_float32), do: 4

  @doc """
  PATCH keys that rewrite data on disk (headroom-gated by the caller).
  `hnsw_config` rebuilds every segment's graph.
  """
  @spec on_disk_keys() :: [String.t()]
  def on_disk_keys, do: ["vectors", "sparse_vectors", "hnsw_config"]

  @doc "Create-collection body: the desired storage params for `version` plus shape."
  @spec create_params(pos_integer(), Version.t() | nil) :: map()
  def create_params(dims, version \\ nil) do
    # float16 halves dense storage (Task 15.1). Only a NEW collection gets
    # it: `diff/2` never compares the datatype, so an existing float32
    # collection is not drift and boot never PATCHes it (Qdrant cannot
    # convert in place).
    dense = %{"size" => dims, "distance" => "Cosine", "on_disk" => true, "datatype" => "float16"}
    body = put_in(storage(version, false), ["vectors", "dense"], dense)

    if tenant_layout?(version),
      do: put_in(body, ["optimizers_config", "max_segment_size"], @max_segment_size_kb),
      else: body
  end

  @doc """
  The desired sub-objects `config` (the GET `result.config`) does not already
  satisfy. `%{}` when everything is applied, so a boot costs no PATCH.
  """
  @spec diff(map(), map()) :: map()
  def diff(config, desired) do
    desired
    |> Enum.reject(fn {key, want} -> subset?(want, get_in(config, @get_path[key])) end)
    |> Map.new()
  end

  defp subset?(want, have) when is_map(want) and is_map(have),
    do: Enum.all?(want, fn {k, v} -> subset?(v, Map.get(have, k)) end)

  defp subset?(want, have), do: want == have
end
