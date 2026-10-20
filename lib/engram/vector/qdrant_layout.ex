defmodule Engram.Vector.QdrantLayout do
  @moduledoc """
  Desired storage + safety params for the EXISTING Qdrant collection, and the
  diff against what `GET /collections/{name}` reports. No HTTP.

  Measured on prod 2026-10-18 (Qdrant Cloud 1.18.2, 447k points): the sparse
  `keyword` index (419 MB) and payload indexes (~140 MB) are the bulk of RAM;
  dense storage is already mmap'd. So this moves the sparse index and dense
  vectors on disk, serialises optimizer rebuilds onto one thread, and turns on
  strict-mode upsert guards for memory and disk.

  On Qdrant >= 1.19.2 (`tenant_layout?/1`, Task 8.1) the graph is per tenant:
  `m: 0` drops the global HNSW graph, `payload_m: 16` builds one per value of
  the `is_tenant` field, every other payload index sets `enable_hnsw: false`,
  and every payload index is on disk. Below 1.19.2 (prod's old 1.18.2
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

  # Task 8.1, Qdrant >= 1.19.2. `max_segment_size` is in KB (1 KB = one
  # 256-dim f32 vector), so about 1 GB per segment.
  @tenant_version "1.19.2"
  @tenant_hnsw %{"m" => 0, "payload_m" => 16, "max_indexing_threads" => 1}
  @max_segment_size_kb 1_000_000

  # Payload fields every tenant-scoped op filters on. Qdrant Cloud strict-mode
  # rejects (400) a filter on an un-indexed field, so each must have an index
  # before any upsert/search/delete (#626). `type_hmac` is the OKF frontmatter
  # `type` blind index (spec 2026-07-02); `folder_hmac`/`tags_hmac` are the
  # folder and tag search filters (#1609). These are the legacy (v3/v4) names;
  # the v5 short-key indexes come from `PayloadKeys.index_fields/0`, and both
  # sets live until the pass drops the legacy fields (Task 18.1).
  @legacy_keyword ~w(user_id vault_id path_hmac type_hmac folder_hmac tags_hmac)
  # OKF frontmatter dates, plaintext so Qdrant can range-filter on them.
  @legacy_integer ~w(fm_timestamp fm_created)
  # No read path filters on `note_id` and v5 points do not carry it (spec
  # 3.3b). Created only on a pre-1.19.2 server with the v5 format off, so such
  # a collection is exactly what main creates. An index that already exists
  # is left alone; the new cluster simply never gets one (Task 8.2).
  @legacy_only ~w(note_id)
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

  @doc """
  The desired PATCH sub-objects for a server at `version` (`nil` = unknown),
  with strict mode refusing writes at `limits` (see `strict_limits/2`;
  default 85/85), or switched off when `strict?` is false.
  Strict mode is included only with at least one guard the server supports:
  enabling it with no guard adds risk for no protection. On `:cloud` it also
  carries `desired_strict/1`, which the kill switch lifts to a ceiling.
  """
  @spec desired(Version.t() | nil, map() | nil, boolean(), :cloud | :self_host) :: map()
  def desired(version, limits \\ @default_limits, strict? \\ true, deployment \\ :self_host)

  # Ops kill switch (QDRANT_STRICT_MODE=false): our two guards at 100 (a
  # refusal only on a full disk/heap), never `enabled: false`, which would also
  # drop Qdrant Cloud's own strict-mode guards (unindexed filtering). 100, not
  # null: the strict-mode PATCH merge keeps the old value for a null field
  # (`x.or(self.x)` in lib/collection/src/operations/config_diff.rs, 1.18.2).
  def desired(version, _limits, false, deployment) do
    case supported_guards(version, @off_limits) do
      [] ->
        storage(version)

      guards ->
        Map.put(
          storage(version),
          "strict_mode_config",
          Map.merge(lifted(deployment), Map.new(guards))
        )
    end
  end

  def desired(version, limits, true, deployment) do
    case supported_guards(version, limits || @default_limits) do
      [] ->
        storage(version)

      guards ->
        strict = Map.merge(desired_strict(deployment), Map.new([{"enabled", true} | guards]))
        Map.put(storage(version), "strict_mode_config", strict)
    end
  end

  @doc "True on Qdrant >= 1.19.2, where the tenant layout applies (Task 8.1); false when unknown."
  @spec tenant_layout?(Version.t() | nil) :: boolean()
  def tenant_layout?(nil), do: false
  def tenant_layout?(version), do: Version.compare(version, @tenant_version) != :lt

  defp storage(version) do
    if tenant_layout?(version) do
      @storage
      |> Map.put("hnsw_config", @tenant_hnsw)
      |> Map.update!("optimizers_config", fn o ->
        Map.merge(o, %{
          "max_segment_size" => @max_segment_size_kb,
          "deleted_threshold" => ServiceConfig.get(:qdrant_deleted_threshold, 0.2)
        })
      end)
    else
      @storage
    end
  end

  @doc """
  The payload indexes to create, `[{field, schema}]`, for a server at
  `version` with the v5 format on or off. Below 1.19.2 these are the pre-8.1
  sets (bare `"keyword"` / `"integer"` schemas, `note_id` while v5 is off).
  On 1.19.2 every index is on disk, `u` is the tenant field, and only the two
  tenant fields build HNSW edges.
  """
  @spec payload_indexes(Version.t() | nil, boolean()) :: [{String.t(), String.t() | map()}]
  def payload_indexes(version, v5?) do
    tenant? = tenant_layout?(version)
    legacy_only = if v5? or tenant?, do: [], else: @legacy_only

    indexes =
      Enum.map(@legacy_keyword ++ legacy_only, &{&1, "keyword"}) ++
        Enum.map(@legacy_integer, &{&1, "integer"}) ++
        if(v5?, do: PayloadKeys.index_fields(), else: [])

    if tenant?, do: Enum.map(indexes, &tenant_schema/1), else: indexes
  end

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

    * disk: reserve `max(1 GiB, 0.35 x collection disk_bytes)` of the
      volume's capacity (0.35 = the on-disk rewrite's measured 0.26x peak
      plus margin);
    * heap: reserve `max(256 MiB, opts.memory_reserve)` of the container
      memory limit (a rewrite's measured heap spike is ~0.25 GB).

  `floor(100 * (size - reserve) / size)`, clamped to 70..95. An unknown size
  keeps `opts.static`. Returns `%{disk: %{percent:, reserve:}, heap: ...}`
  (`reserve` nil when static).
  """
  @spec strict_limits(map(), map()) :: map()
  def strict_limits(%{capacity: cap, collection: coll, memory_limit: mem}, opts) do
    # ponytail: 0.35x is the whole-collection rewrite budget; switch the disk
    # reserve to 2 x max_segment_size once segments are capped.
    disk_reserve = if is_integer(coll), do: max(@gib, div(coll * 35, 100))
    heap_reserve = max(@min_memory_reserve, opts.memory_reserve)

    %{
      disk: limit(cap, disk_reserve, opts.static.disk),
      heap: limit(mem, heap_reserve, opts.static.heap)
    }
  end

  defp limit(size, reserve, _static) when is_integer(size) and size > 0 and is_integer(reserve),
    do: %{percent: (100 * (size - reserve)) |> div(size) |> max(70) |> min(95), reserve: reserve}

  defp limit(_size, _reserve, static), do: %{percent: static, reserve: nil}

  @doc """
  PATCH keys that rewrite data on disk (headroom-gated by the caller).
  `hnsw_config` rebuilds every segment's graph.
  """
  @spec on_disk_keys() :: [String.t()]
  def on_disk_keys, do: ["vectors", "sparse_vectors", "hnsw_config"]

  @doc "Create-collection body: the desired storage params for `version` plus shape."
  @spec create_params(pos_integer(), boolean(), Version.t() | nil) :: map()
  def create_params(dims, float16? \\ false, version \\ nil) do
    dense = %{"size" => dims, "distance" => "Cosine", "on_disk" => true}

    # float16 halves dense storage (Task 15.1), only with the v5 payload
    # format on. Only a NEW collection gets it: `diff/2` never compares the
    # datatype, so an existing float32 collection is not drift and boot never
    # PATCHes it (Qdrant cannot convert in place).
    dense = if float16?, do: Map.put(dense, "datatype", "float16"), else: dense
    put_in(storage(version), ["vectors", "dense"], dense)
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
