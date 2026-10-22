import Config

# Prod delivers all app secrets as one SSM SecureString (1 KMS decrypt
# instead of one per secret). Expand it into the process env BEFORE the
# System.get_env/1 reads below so they resolve unchanged. Self-host/dev set
# individual env vars and never set APP_SECRETS_JSON, so this is a no-op.
# Malformed JSON raises here → boot fails loud rather than starting with
# missing secrets.
if blob = System.get_env("APP_SECRETS_JSON") do
  Engram.Secrets.unpack(blob, &System.get_env/1)
  |> Enum.each(fn {k, v} -> System.put_env(k, v) end)
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/engram start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :engram, EngramWeb.Endpoint, server: true
end

config :engram, EngramWeb.Endpoint,
  http: [
    port: String.to_integer(System.get_env("PORT", "4000")),
    # Merges into config.exs's http_options. See RuntimeConfig.http_compression/1.
    http_options: Engram.RuntimeConfig.http_compression(&System.get_env/1)
  ]

# Env-derived dev/test settings. These must NOT live in dev.exs/test.exs.
# Those files are compile-time config, and when a config file is newer than
# the compile manifest Mix compares the app's compile-time config to the one
# it compiled with; any difference in :engram's config recompiles the whole app.
# CI compiles once in prebuild-mix, then every job runs with its own
# DATABASE_URL, PORT, MIX_TEST_PARTITION and scheduler count, so an env read
# in those files made each job discard the prebuilt _build and recompile all
# ~480 files plus the Rust NIF. runtime.exs is not part of that comparison.
if config_env() in [:dev, :test] do
  default_database =
    if config_env() == :test, do: "engram_test", else: "engram_dev"

  # MIX_TEST_PARTITION suffixes the database (`mix test --partitions N` gets
  # one DB each), including on a DATABASE_URL (`.../engram_test` ->
  # `.../engram_test2`).
  partition = if config_env() == :test, do: System.get_env("MIX_TEST_PARTITION") || "", else: ""

  repo_conn =
    case System.get_env("DATABASE_URL") do
      nil ->
        [
          username: "engram",
          password: "engram",
          hostname: "localhost",
          database: default_database <> partition
        ]

      url ->
        uri = URI.parse(url)
        [url: URI.to_string(%{uri | path: uri.path <> partition})]
    end

  config :engram, Engram.Repo, repo_conn
end

if config_env() == :test do
  config :engram,
         Engram.Repo,
         # Headroom over ExUnit's concurrency limit is deliberate and load-bearing.
         #
         # ExUnit's default `max_cases` is ALSO `System.schedulers_online() * 2`, so
         # sizing the pool to exactly that leaves zero spare connections: with every
         # async slot holding a checkout, any additional connection queues on an
         # empty pool and waits out the 15s timeout. That is #1158 — a whole module
         # failing in `setup` with "connection not available and request was dropped
         # from queue", which looks like a defect in whichever module lost the race
         # rather than the resource shape it actually is.
         #
         # Two things need that spare capacity: a sync (`async: false`) module's own
         # checkout, and any process a test spawns that does its own DB work (the
         # `:global` CRDT rooms in Engram.Notes.CrdtTransportTest are the case that
         # surfaced this).
         #
         # Raising the checkout timeout instead would only lengthen the queue wait —
         # it hides the contention rather than removing it.
         pool_size: System.schedulers_online() * 2 + 10
end

if config_env() == :dev do
  # Default :debug; the Playwright e2e servers set LOG_LEVEL=info in CI.
  config :logger, level: String.to_existing_atom(System.get_env("LOG_LEVEL", "debug"))
end

# Model per plan (SaaS, billing on, `EMBED_MODELS_PER_PLAN=true`):
# `{DOC,QUERY}_EMBED_MODEL_{FREE,STARTER,PRO}`.
# Only the set ones are configured; an unset or blank plan reads its default
# in `Engram.EmbedModels` (`plan_defaults/0`, the one copy: Free
# voyage-4-lite, Starter and Pro voyage-4-large). Self-host ignores them.
plan_models = fn prefix ->
  for plan <- [:free, :starter, :pro],
      model = System.get_env("#{prefix}_#{String.upcase(to_string(plan))}", "") |> String.trim(),
      model != "",
      into: %{},
      do: {plan, model}
end

# The switch: unset or anything but "true" keeps one model for every plan
# (the global ones), as before v5. Flipped at v5 go time.
if per_plan = System.get_env("EMBED_MODELS_PER_PLAN") do
  config :engram, :embed_models_per_plan, per_plan == "true"
end

config :engram, :plan_doc_embed_models, plan_models.("DOC_EMBED_MODEL")
config :engram, :plan_query_embed_models, plan_models.("QUERY_EMBED_MODEL")

if config_env() != :test do
  # Storage backend. Default "s3" is the SaaS/prod path (AWS S3) and the
  # standard self-host path (MinIO). "database" is a self-host-only convenience
  # (#297) that stores attachment bytes in Postgres `bytea` so a minified stack
  # can drop MinIO — not for scale (that's why BYTEA was removed for SaaS in
  # A.5/PR #62); it stores opaque ciphertext in a generic `storage_objects`
  # table, NOT the old `attachments.content` column.
  case System.get_env("STORAGE_BACKEND", "s3") do
    "s3" ->
      config :engram, :storage, Engram.Storage.S3
      config :engram, :storage_bucket, System.get_env("STORAGE_BUCKET", "engram-attachments")

      # Explicit static creds (MinIO, non-AWS S3, self-host) — only set
      # when STORAGE_ACCESS_KEY_ID is present. On AWS ECS Fargate
      # leaving these unset lets ex_aws fall back to the task role via
      # the AWS_CONTAINER_CREDENTIALS_RELATIVE_URI metadata endpoint.
      if System.get_env("STORAGE_ACCESS_KEY_ID") do
        config :ex_aws,
          access_key_id: System.fetch_env!("STORAGE_ACCESS_KEY_ID"),
          secret_access_key: System.fetch_env!("STORAGE_SECRET_ACCESS_KEY"),
          region: System.get_env("STORAGE_REGION", "auto")
      else
        config :ex_aws,
          region: System.get_env("STORAGE_REGION", System.get_env("AWS_REGION", "us-east-1"))
      end

      # Endpoint override (MinIO, non-AWS S3) — only when STORAGE_HOST is
      # set. AWS-native S3 leaves this unset so ex_aws uses its default
      # regional endpoint.
      if System.get_env("STORAGE_HOST") do
        config :ex_aws, :s3,
          scheme: System.get_env("STORAGE_SCHEME", "https://"),
          host: System.fetch_env!("STORAGE_HOST"),
          port: String.to_integer(System.get_env("STORAGE_PORT", "443"))
      end

    "database" ->
      config :engram, :storage, Engram.Storage.Database

    other ->
      raise """
      Unknown STORAGE_BACKEND=#{inspect(other)} — supported values are
      "s3" (default; AWS S3 prod / self-host MinIO) and "database"
      (self-host-only Postgres bytea, #297).
      """
  end

  # Embedder — select adapter from EMBED_BACKEND env var (voyage or ollama)
  case System.get_env("EMBED_BACKEND", "voyage") do
    "ollama" ->
      config :engram, :embedder, Engram.Embedders.Ollama

    _ ->
      config :engram, :embedder, Engram.Embedders.Voyage

      if api_key = System.get_env("VOYAGE_API_KEY") do
        config :engram, :voyage_api_key, api_key
      end
  end

  if System.get_env("EMBED_MODEL") do
    config :engram, :embed_model, System.get_env("EMBED_MODEL")
  end

  if System.get_env("EMBED_DIMS") do
    config :engram, :embed_dims, String.to_integer(System.get_env("EMBED_DIMS"))
  end

  # Asymmetric retrieval: separate models for doc indexing vs search queries.
  # Falls back to EMBED_MODEL if not set (symmetric mode).
  if doc_model = System.get_env("DOC_EMBED_MODEL") do
    config :engram, :doc_embed_model, doc_model
  end

  if query_model = System.get_env("QUERY_EMBED_MODEL") do
    config :engram, :query_embed_model, query_model
  end

  # BEAM scheduler priority for embed/indexing job processes. `:low` (default)
  # means a job only runs when no `:normal` process — every Phoenix channel
  # serving a live sync — is runnable on that scheduler, so a bulk upload can
  # no longer starve the user's own sync. Kill-switch: set `normal` to revert
  # without a deploy if indexing ever starves under sustained load. Only
  # `normal` and `low` are accepted; anything else would be passed straight to
  # `process_flag/2` and crash every job.
  case System.get_env("BACKGROUND_JOB_PRIORITY") do
    nil -> :ok
    "normal" -> config :engram, :background_job_priority, :normal
    "low" -> config :engram, :background_job_priority, :low
    other -> raise "BACKGROUND_JOB_PRIORITY must be \"normal\" or \"low\", got: #{inspect(other)}"
  end

  # Voyage 429 → snooze duration (seconds). Tune as Voyage RPM grows: lower
  # values churn jobs faster once budget is restored; higher values are gentler
  # on a small bucket. Default 60s suits both free-tier (3 RPM) and paid.
  if secs = System.get_env("EMBED_429_SNOOZE_SECONDS") do
    config :engram, :embed_429_snooze_seconds, String.to_integer(secs)
  end

  # Settle debounce: a note must sit unedited this many seconds before it embeds,
  # so a burst of rapid saves collapses into one Voyage call. Higher = cheaper but
  # staler search index after an edit. Default 30s.
  if secs = System.get_env("EMBED_SETTLE_SECONDS") do
    config :engram, :embed_settle_seconds, String.to_integer(secs)
  end

  # Max-wait ceiling: a continuously-edited note embeds at most this many seconds
  # after its first pending edit, even if never quiet (prevents starvation).
  # Default 300s (5m). Keep > EMBED_SETTLE_SECONDS.
  if secs = System.get_env("EMBED_SETTLE_MAX_WAIT_SECONDS") do
    config :engram, :embed_settle_max_wait_seconds, String.to_integer(secs)
  end

  # Cooldown (seconds) parked on a note that exhausts its embed attempts, before
  # ReconcileEmbeddings retries it. Caps re-billing on permanently-failing notes.
  # Default 6h (21_600). Lower it to retry broken notes sooner at higher cost.
  if secs = System.get_env("EMBED_POISON_COOLDOWN_SECONDS") do
    config :engram, :embed_poison_cooldown_seconds, String.to_integer(secs)
  end

  # Shorter cooldown for TRANSIENT embed failures (upstream unreachable / 5xx) so
  # a provider blip doesn't strand notes for the full poison window. Default 300s;
  # effective recovery is bounded below by the 5-min ReconcileEmbeddings sweep.
  if secs = System.get_env("EMBED_TRANSIENT_COOLDOWN_SECONDS") do
    config :engram, :embed_transient_cooldown_seconds, String.to_integer(secs)
  end

  # Preemptive cooldown (seconds) ReconcileEmbeddings stamps on every note it
  # enqueues (#897). Makes the backoff crash-independent: an OOM/node kill that
  # bypasses the graceful poison stamp still can't cause immediate re-enqueue.
  # MUST exceed the 5-min reconcile cron interval. Default 30m (1_800).
  if secs = System.get_env("EMBED_RECONCILE_BACKOFF_SECONDS") do
    config :engram, :embed_reconcile_backoff_seconds, String.to_integer(secs)
  end

  # Client-side Voyage rate limit. Unset = no throttle (self-host default).
  # Set to your Voyage paid-tier RPM (e.g. 2000) to fail fast with a synthetic
  # 429 before burning real API calls. EmbedNote snoozes on the synthetic 429
  # just like a real one. Bump this as the Voyage allotment grows.
  #
  # `VOYAGE_QUERY_RPM` (optional) gives synchronous user search its own
  # bucket so a bulk indexing burst can't starve queries. Falls back to
  # `VOYAGE_RPM` when unset. Recommended: reserve ~20% of total RPM for
  # queries (set VOYAGE_QUERY_RPM to ~0.2*total and VOYAGE_RPM to ~0.8*total).
  if rpm = System.get_env("VOYAGE_RPM") do
    config :engram, :voyage_rpm, String.to_integer(rpm)
  end

  if query_rpm = System.get_env("VOYAGE_QUERY_RPM") do
    config :engram, :voyage_query_rpm, String.to_integer(query_rpm)
  end

  if System.get_env("QDRANT_URL") do
    config :engram, :qdrant_url, System.get_env("QDRANT_URL")
  end

  if System.get_env("QDRANT_COLLECTION") do
    config :engram, :qdrant_collection, System.get_env("QDRANT_COLLECTION")
  end

  if qdrant_api_key = System.get_env("QDRANT_API_KEY") do
    config :engram, :qdrant_api_key, qdrant_api_key
  end

  # The second Qdrant cluster for the v5 move. Unset, nothing changes: the
  # client talks to QDRANT_URL. Set, `:qdrant_active_cluster` (a runtime
  # override, `Engram.ServiceConfig.override/3`) picks `old` or `v2` per call.
  # The key needs manage rights (collection create, payload indexes, config
  # PATCH), as QDRANT_API_KEY does.
  if qdrant_url_v2 = System.get_env("QDRANT_URL_V2") do
    config :engram, :qdrant_url_v2, qdrant_url_v2
  end

  if qdrant_api_key_v2 = System.get_env("QDRANT_API_KEY_V2") do
    config :engram, :qdrant_api_key_v2, qdrant_api_key_v2
  end

  # Binary quantization — requires AVX2+ CPU. Disable on older hardware.
  if System.get_env("QDRANT_BINARY_QUANTIZATION") == "false" do
    config :engram, :qdrant_binary_quantization, false
  end

  # Reranker — select adapter from RERANKER_BACKEND env var (jina or none)
  case System.get_env("RERANKER_BACKEND", "none") do
    "jina" ->
      config :engram, :reranker, Engram.Rerankers.Jina

      config :engram,
             :jina_url,
             System.get_env("JINA_URL") ||
               raise("JINA_URL is required when RERANKER_BACKEND=jina")

    _ ->
      config :engram, :reranker, Engram.Rerankers.None
  end
end

# Qdrant backpressure + ops kill switches. Outside the non-test block on
# purpose: read in every environment (prod and self-host), and only set when
# the env var is present, so code defaults (all switches ON) stay in force.
qdrant_switch = fn var ->
  case System.get_env(var) do
    nil -> nil
    v when v in ["true", "1"] -> true
    v when v in ["false", "0"] -> false
    _ -> raise "#{var} must be true or false"
  end
end

# false = never PATCH the collection config (boot reconcile and the poller).
case qdrant_switch.("QDRANT_RECONCILE_CONFIG") do
  nil -> :ok
  on? -> config :engram, :qdrant_reconcile_config, on?
end

# false = skip only the on-disk group (dense + sparse index on disk).
case qdrant_switch.("QDRANT_RECONCILE_ON_DISK") do
  nil -> :ok
  on? -> config :engram, :qdrant_reconcile_on_disk, on?
end

# false = the reconcile actively sets strict_mode_config.enabled=false, so
# write refusals can be turned off with an env change + restart.
case qdrant_switch.("QDRANT_STRICT_MODE") do
  nil -> :ok
  on? -> config :engram, :qdrant_strict_mode, on?
end

# cloud | self_host = which strict-mode hard limits the reconcile applies,
# instead of reading it from the QDRANT_URL host (`Qdrant.deployment/1`).
# Lets staging (self-host) rehearse the Qdrant Cloud limits.
case System.get_env("QDRANT_STRICT_PROFILE") do
  "cloud" -> config :engram, :qdrant_strict_profile, :cloud
  "self_host" -> config :engram, :qdrant_strict_profile, :self_host
  _ -> :ok
end

# true = on Qdrant 1.19+ the reconcile also manages the node-wide `/quotas`
# (disk + memory write guards). Node-wide: set it only where the Qdrant server
# holds this app's collection alone (Qdrant Cloud prod). Default false.
case qdrant_switch.("QDRANT_MANAGE_QUOTAS") do
  nil -> :ok
  on? -> config :engram, :qdrant_manage_quotas, on?
end

# true = the keyword leg computes IDF over the user's own points (Qdrant
# 1.19+, users with >= :tenant_idf_min_points points). Default false: it
# changes keyword ranking, so it is flipped at v5 go time, and false here
# turns it off again without a deploy.
case qdrant_switch.("TENANT_IDF") do
  nil -> :ok
  on? -> config :engram, :tenant_idf, on?
end

# v5 rebuild tuning (INFRA-5 sets these on the web and worker task defs).
# Unset, nothing is configured and each reader's default applies: 0.2, 0.25,
# 1_000, true and [] (today's behaviour). A malformed value refuses to boot.
unit_fraction = fn var ->
  with v when is_binary(v) <- System.get_env(var) do
    case Float.parse(v) do
      {f, ""} when f >= 0 and f <= 1 -> f
      _ -> raise "#{var} must be a number from 0 to 1, got #{inspect(v)}"
    end
  end
end

# Qdrant optimizer `deleted_threshold` on the collection (`QdrantLayout`).
if threshold = unit_fraction.("QDRANT_DELETED_THRESHOLD") do
  config :engram, :qdrant_deleted_threshold, threshold
end

# BM25 `b` for merged (capped) chunks (`Indexing`).
if b = unit_fraction.("BM25_B_MERGED") do
  config :engram, :bm25_b_merged, b
end

# Points a user needs before TENANT_IDF computes IDF over their own points.
if min_points = System.get_env("TENANT_IDF_MIN_POINTS") do
  case Integer.parse(min_points) do
    {n, ""} when n >= 0 -> config :engram, :tenant_idf_min_points, n
    _ -> raise "TENANT_IDF_MIN_POINTS must be a non-negative integer, got #{inspect(min_points)}"
  end
end

# true = filters also match the v3 `*_hmac` payload fields; false only after
# the v5 pass has rewritten every point (PR-18).
case qdrant_switch.("LEGACY_FILTER_FIELDS") do
  nil -> :ok
  on? -> config :engram, :legacy_filter_fields, on?
end

# The v5 layout switches (chunker v5 plan), all off by default; unset leaves
# the key unconfigured so the code default (off, today's behaviour) applies.
# WRITE_V5_LAYOUT implies the v5 payload format (`Qdrant.v5_payload_format?/0`)
# and chunk text reads (`Qdrant.chunk_text_read?/0`; v5 points hold no text
# in Qdrant), and is what `INDEX_REBUILD=on` requires (`Rebuild.mode/0` reads `off`
# without it).
for {var, key} <- [
      {"WRITE_V5_LAYOUT", :write_v5_layout},
      {"V5_PAYLOAD_FORMAT", :v5_payload_format},
      {"CHUNK_TEXT_WRITE", :chunk_text_write},
      {"CHUNK_TEXT_READ", :chunk_text_read},
      {"QDRANT_TENANT_GRAPH", :qdrant_tenant_graph}
    ] do
  case qdrant_switch.(var) do
    nil -> :ok
    on? -> config :engram, key, on?
  end
end

# The per-tenant HNSW graph only after drop-legacy-fields (PR-18): with legacy
# points left, one user would be two disconnected subgraphs.
if qdrant_switch.("QDRANT_TENANT_GRAPH") == true and
     qdrant_switch.("LEGACY_FILTER_FIELDS") != false do
  raise "QDRANT_TENANT_GRAPH=true needs LEGACY_FILTER_FIELDS=false (after the v5 pass, PR-18)"
end

# Comma-separated user ids the v5 pass rebuilds last (`Rebuild.rebuild_order/1`).
if last_users = System.get_env("REBUILD_LAST_USERS") do
  ids =
    for id <- last_users |> String.split(",") |> Enum.map(&String.trim/1), id != "" do
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> uuid
        :error -> raise "REBUILD_LAST_USERS must be comma-separated user ids, got #{inspect(id)}"
      end
    end

  config :engram, :rebuild_last_users, ids
end

# false = EmbedNote never pauses for Qdrant pressure before paying Voyage.
case qdrant_switch.("QDRANT_BACKPRESSURE_PREFLIGHT") do
  nil -> :ok
  on? -> config :engram, :qdrant_backpressure_preflight, on?
end

# Qdrant container memory limit (bytes): the heap pressure reading and the
# strict-mode memory limit. Unset = heap is not checked, limit stays static.
if v = System.get_env("QDRANT_MEMORY_LIMIT_BYTES"),
  do: config(:engram, :qdrant_memory_limit_bytes, String.to_integer(v))

# Heap kept free below that limit (floor 256 MiB).
if v = System.get_env("QDRANT_MEMORY_RESERVE_BYTES"),
  do: config(:engram, :qdrant_memory_reserve_bytes, String.to_integer(v))

# Static strict-mode percents, used only when a size is unknown.
if v = System.get_env("QDRANT_STRICT_DISK_PERCENT"),
  do: config(:engram, :qdrant_strict_disk_percent, String.to_integer(v))

if v = System.get_env("QDRANT_STRICT_MEMORY_PERCENT"),
  do: config(:engram, :qdrant_strict_memory_percent, String.to_integer(v))

# EmbedNote pauses this many points below each strict-mode limit.
if v = System.get_env("QDRANT_PREFLIGHT_MARGIN_POINTS"),
  do: config(:engram, :qdrant_preflight_margin_points, String.to_integer(v))

# Auth provider selection: "local" (built-in email/password) or "clerk" (SaaS JWKS)
# Default: local — self-hosters get working auth with zero third-party config.
auth_provider =
  case System.get_env("AUTH_PROVIDER", "local") do
    "local" -> :local
    "clerk" -> :clerk
    other -> raise "Invalid AUTH_PROVIDER=#{other}. Valid values: local, clerk"
  end

config :engram, :auth_provider, auth_provider

# Compress-then-encrypt kill switch (#1872). Default (config.exs) is on; set
# ENVELOPE_COMPRESSION=false and restart to return new writes to format 0.
# Existing format-1 rows stay readable.
case Engram.RuntimeConfig.envelope_compression(&System.get_env/1) do
  {:ok, flag} -> config :engram, :envelope_compression, flag
  :unset -> :ok
end

# Self-host registration mode default (Engram.Instance.registration_mode/0).
# Production default is "invite_only" — the spec's safety posture. CI/dev can
# pin "open" so fixtures that register many users don't need to seed the gate.
default_registration_mode =
  case System.get_env("ENGRAM_DEFAULT_REGISTRATION_MODE", "invite_only") do
    mode when mode in ~w(closed invite_only open) ->
      mode

    other ->
      raise "Invalid ENGRAM_DEFAULT_REGISTRATION_MODE=#{other}. Valid: closed, invite_only, open"
  end

config :engram, :default_registration_mode, default_registration_mode

# Upgrade URL surfaced in 402 limit-exceeded responses (see EngramWeb.LimitResponse).
# SaaS points at the in-app billing page; self-hosters can override or set to nil.
config :engram,
       :upgrade_url,
       System.get_env("ENGRAM_UPGRADE_URL", "https://app.engram.page/#settings/billing")

# Email transactional provider (pricing v2 §C). Default: NoOp for self-host;
# Resend when RESEND_API_KEY is set.
#
# Gated to non-test envs so a developer's shell-exported RESEND_API_KEY
# can't silently flip `mix test` from NoOp to a real Resend send. test.exs
# pins :email_provider to Engram.Email.Resend's NoOp sibling; runtime.exs
# loads AFTER test.exs and would otherwise override it, causing unit tests
# that exercise Mailer paths (profile_test, users_controller_test calling
# delete_self → Lifecycle.soft_delete → Mailer.send_account_deleted_notice)
# to fire real emails to test-fixture addresses. Mirrors the test guard
# already applied to storage (line 26), sentry (line 312), and key_provider
# (line 396) blocks.
if config_env() != :test do
  if api_key = System.get_env("RESEND_API_KEY") do
    config :engram, :email_provider, Engram.Email.Resend
    config :engram, :resend_api_key, api_key
  end

  if email_from = System.get_env("EMAIL_FROM") do
    config :engram, :email_from, email_from
  end

  # Resend bounce/complaint webhook secret (whsec_*), verifies inbound svix
  # signatures at POST /webhooks/resend. Without it the endpoint rejects all
  # events (cannot verify → cannot accept).
  if wh_secret = System.get_env("RESEND_WEBHOOK_SECRET") do
    config :engram, :resend_webhook_secret, String.trim(wh_secret)
  end
end

# Rate-limit overrides for CI/E2E stacks only, each gated on CI=true so a stray
# copy in a prod task def can never weaken a limiter. CI stacks (ci/compose*.yml,
# the Playwright runner) set CI=true; production never does. The list of
# overridable limiters lives in Engram.RuntimeConfig.
require Logger

rate_limit_overrides =
  Enum.flat_map(Engram.RuntimeConfig.rate_limit_overrides(), fn {env_var, key} ->
    case Engram.RuntimeConfig.ci_gated_int_override(&System.get_env/1, env_var) do
      {:ok, limit} ->
        [{key, limit}]

      {:ignored, raw} ->
        Logger.warning(
          "#{env_var}=#{raw} ignored: rate-limit overrides are only honored when CI=true."
        )

        []

      :none ->
        []
    end
  end)

if rate_limit_overrides != [] do
  config :engram, rate_limit_overrides
end

# NOTE: the drain's fleet-wide defaults are NOT set here. They are module
# defaults (`CrdtCheckpointTimer.@default_idle_exit_ms`,
# `CrdtRoomLru.@default_max_resident`) so every environment is bounded without
# having to remember to configure it. Setting CRDT_IDLE_EXIT_MS in an ECS task
# definition would NOT work: ci_gated_int_override/2 below ignores it unless
# CI=true, and only logs a warning.
#
# CRDT room-drain levers (#1152) — CI/E2E only, same CI=true gate. Each targets
# a NESTED config key (module + key) rather than the flat app-env keys above, so
# the pairs live in RuntimeConfig and DRIVE this loop. Writing them out longhand
# here instead would leave that list consumed only by its own test, and a fourth
# lever added on one side would pass every check.
Enum.each(Engram.RuntimeConfig.drain_overrides(), fn {var, {mod, key}} ->
  case Engram.RuntimeConfig.ci_gated_int_override(&System.get_env/1, var) do
    {:ok, value} ->
      config :engram, mod, [{key, value}]

    {:ignored, raw} ->
      Logger.warning("#{var}=#{raw} ignored: drain levers are only honored when CI=true.")

    :none ->
      :ok
  end
end)

# Clerk auth (only required when AUTH_PROVIDER=clerk)
# Note: use local variable, not Application.get_env — runtime.exs config
# is accumulated and not yet applied, so get_env reads stale config.
if auth_provider == :clerk do
  clerk_jwks_url =
    System.get_env("CLERK_JWKS_URL") ||
      raise "CLERK_JWKS_URL is required when AUTH_PROVIDER=clerk"

  config :engram, :clerk_jwks_url, String.trim(clerk_jwks_url)

  clerk_issuer =
    System.get_env("CLERK_ISSUER") ||
      raise "CLERK_ISSUER is required when AUTH_PROVIDER=clerk"

  config :engram, :clerk_issuer, String.trim(clerk_issuer)

  clerk_pub_key =
    case System.get_env("CLERK_PUBLISHABLE_KEY") do
      nil -> raise "CLERK_PUBLISHABLE_KEY is required when AUTH_PROVIDER=clerk"
      "" -> raise "CLERK_PUBLISHABLE_KEY is set but empty when AUTH_PROVIDER=clerk"
      key -> key
    end

  config :engram, :clerk_publishable_key, clerk_pub_key

  # Backend API key (sk_*) — required to revoke duplicate signups detected by
  # pricing v2 §A. Webhook secret (whsec_*) verifies inbound svix signatures.
  if secret_key = System.get_env("CLERK_SECRET_KEY") do
    config :engram, :clerk_secret_key, String.trim(secret_key)
  end

  if wh_secret = System.get_env("CLERK_WEBHOOK_SECRET") do
    config :engram, :clerk_webhook_secret, String.trim(wh_secret)
  end

  # Optional `azp` (Authorized Party) allowlist. Comma-separated origins, e.g.
  # "https://app.engram.page,https://staging.engram.page". Empty/unset →
  # passthrough — mirrors @clerk/backend's `assertAuthorizedPartiesClaim` so
  # self-host Clerk users aren't forced to configure it just to get auth working.
  clerk_authorized_parties =
    case System.get_env("CLERK_AUTHORIZED_PARTIES") do
      nil ->
        []

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end

  config :engram, :clerk_authorized_parties, clerk_authorized_parties
end

# Attachment executable blocklist self-host knob. Default: gate is ON.
# Operators who want to allow executables (e.g. distributing an internal tool
# from a self-hosted vault) set ATTACHMENT_MIME_BYPASS=true.
if System.get_env("ATTACHMENT_MIME_BYPASS") in ["1", "true"] do
  config :engram, :attachment_mime_bypass, true
end

# Vault-channel CRDT fan-out pacer (engram-app/Engram#1002) rollback knob.
# Default is pacing ON; set to "false" to fall back to unpaced inline
# broadcast for every note if the pacer ever needs to be disabled in prod.
#
# KEEP until #1004 is closed. This is deliberately a documented config path
# rather than a per-node remote-console `Application.put_env` — that was the
# explicit ask in #1004. The queue-depth gauge shipped (#1487); the alarm in
# #1004 is still open.
# The v5 index budget (`Engram.Indexing.budget_enabled?/0`): per-note cap
# merge, points budget and floor, the 04:00 UTC recap and budget sweeps.
# Off until the v5 pass completes; turned on with the v5 stamp.
if budget = System.get_env("INDEX_BUDGET_ENABLED") do
  config :engram, :index_budget_enabled, budget == "true"
end

# The one-time v5 index rebuild switch (`Engram.Rebuild`, chunker v5 Task
# 16.1): `off` (default), `dry_run` or `on`. Off, a stamp bump rebuilds
# nothing and nothing reads the rebuild tables.
if rebuild = System.get_env("INDEX_REBUILD") do
  config :engram, :index_rebuild, rebuild
end

# The encrypted per-user vector cache (`Engram.Indexing.VectorCache`, chunker
# v5 Task 12): a text is paid to Voyage once. Off by default; off, the embed
# path never reads or writes `embedding_cache`.
if cache = System.get_env("VECTOR_CACHE_ENABLED") do
  config :engram, :vector_cache_enabled, cache == "true"
end

if pacing = System.get_env("FANOUT_PACING_ENABLED") do
  config :engram, :fanout_pacing_enabled, pacing == "true"
end

# Paddle billing (Merchant-of-Record). Secret/server keys are required only
# when actually calling the Paddle API; the public client_token + price_ids
# are required for the frontend overlay. PADDLE_ENV chooses sandbox vs prod.
if config_env() != :test do
  if api_key = System.get_env("PADDLE_API_KEY") do
    config :engram, :paddle_api_key, api_key
  end

  if secret = System.get_env("PADDLE_NOTIFICATION_SECRET") do
    config :engram, :paddle_notification_secret, secret
  end

  if token = System.get_env("PADDLE_CLIENT_TOKEN") do
    config :engram, :paddle_client_token, token
  end

  config :engram,
         :paddle_starter_monthly_price_id,
         System.get_env("PADDLE_STARTER_MONTHLY_PRICE_ID")

  config :engram,
         :paddle_starter_annual_price_id,
         System.get_env("PADDLE_STARTER_ANNUAL_PRICE_ID")

  config :engram,
         :paddle_pro_monthly_price_id,
         System.get_env("PADDLE_PRO_MONTHLY_PRICE_ID")

  config :engram,
         :paddle_pro_annual_price_id,
         System.get_env("PADDLE_PRO_ANNUAL_PRICE_ID")

  config :engram, :paddle_env, System.get_env("PADDLE_ENV", "sandbox")
end

# Onboarding wizard toggle. Self-host (AUTH_PROVIDER=local) never shows the
# SaaS wizard — operators own their own legal posture and there is no Paddle.
# SaaS (clerk) needs the wizard whenever the Paddle API key is configured.
config :engram,
       :billing_enabled,
       auth_provider == :clerk and System.get_env("PADDLE_API_KEY") != nil

# Plan limits enforcement toggle.
# SaaS default: enforce when Paddle is configured.
# Self-host default: bypass when no Paddle key.
# Explicit override: ENGRAM_LIMITS_ENFORCED=true|false
# Test env: config/test.exs hardcodes true; do not override at runtime.
if config_env() != :test do
  limits_enforced =
    case System.get_env("ENGRAM_LIMITS_ENFORCED") do
      "true" ->
        true

      "false" ->
        false

      nil ->
        auth_provider == :clerk and System.get_env("PADDLE_API_KEY") != nil

      other ->
        raise """
        ENGRAM_LIMITS_ENFORCED must be 'true', 'false', or unset (got #{inspect(other)}).
        """
    end

  config :engram, :limits_enforced, limits_enforced

  # Plan limit overrides from env vars. Each ENGRAM_<TIER>_<KEY> is parsed at
  # boot. Bad values raise a fail-fast boot error per EnvLimits.parse!/3.
  # Test env: tests set :plan_overrides directly via Application.put_env;
  # do not override here.
  plan_overrides =
    for {tier, key, env_name} <- Engram.Billing.LimitKeys.env_var_names(),
        raw = System.get_env(env_name),
        raw != nil,
        into: %{} do
      typed = Engram.Billing.EnvLimits.parse!(raw, Engram.Billing.LimitKeys.type(key), env_name)
      {{tier, key}, typed}
    end

  config :engram, :plan_overrides, plan_overrides
end

# Legal versions/hashes now live in the terms_versions table (Engram.Legal), seeded from priv/legal/legal-manifest.json at boot.

# Key provider — skip in :test so test.exs stable key is not overwritten by a nil env read.
# Dev and prod (including Docker CI containers) read from KEY_PROVIDER / ENCRYPTION_MASTER_KEY.
if config_env() != :test do
  key_provider_module =
    case System.get_env("KEY_PROVIDER", "local") do
      "local" -> Engram.Crypto.KeyProvider.Local
      "aws_kms" -> Engram.Crypto.KeyProvider.AwsKms
      other -> raise "Unknown KEY_PROVIDER=#{other}; supported: local | aws_kms"
    end

  config :engram,
    key_provider: key_provider_module,
    encryption_master_key: System.get_env("ENCRYPTION_MASTER_KEY"),
    encryption_master_key_previous: System.get_env("ENCRYPTION_MASTER_KEY_PREVIOUS"),
    encryption_master_key_version:
      String.to_integer(System.get_env("ENCRYPTION_MASTER_KEY_VERSION", "1")),
    dek_cache_ttl_ms: String.to_integer(System.get_env("DEK_CACHE_TTL_MS", "3600000"))

  # T3.5 master-key rotation needs the boot canary disabled during the
  # window between bumping ENCRYPTION_MASTER_KEY and running
  # `Engram.Crypto.MasterRotation.rotate_canary/0` (the canary row is
  # still wrapped under the OLD key and `unwrap_dek_no_fallback/2`
  # refuses to consult `_PREVIOUS`). Operator sets BOOT_CANARY_ENABLED=false
  # in the SOPS-managed env, restarts, runs rotation, then removes the
  # env var. See backend/docs/context/encryption-operations.md
  # "Tier-3 / T3.5 — Master-key rotation runbook".
  if System.get_env("BOOT_CANARY_ENABLED") == "false" do
    config :engram, :boot_canary_enabled, false
  end

  if key_provider_module == Engram.Crypto.KeyProvider.AwsKms do
    config :engram,
      aws_kms_client: Engram.AwsKms.ExAws,
      aws_kms_key_id: System.fetch_env!("AWS_KMS_KEY_ID"),
      aws_kms_region: System.fetch_env!("AWS_REGION")

    # Scoped to :ex_aws, :kms so KMS creds don't overwrite the global
    # :ex_aws creds that the S3 storage backend (AWS S3 / MinIO)
    # may have configured above.
    #
    # Explicit static creds (a non-task-role AWS access key for KMS, local
    # dev) — only set when AWS_ACCESS_KEY_ID is present. On AWS ECS
    # Fargate leaving these unset lets ex_aws fall back to the task
    # role via AWS_CONTAINER_CREDENTIALS_RELATIVE_URI.
    if System.get_env("AWS_ACCESS_KEY_ID") do
      config :ex_aws, :kms,
        access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
        secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
        region: System.fetch_env!("AWS_REGION")
    else
      config :ex_aws, :kms, region: System.fetch_env!("AWS_REGION")
    end
  end
end

# Endpoint URL — used by EngramWeb.Endpoint.url() for device flow verification links,
# email URLs, etc. Works in dev and prod. Defaults to localhost in dev.
# PHX_HOST may be a comma-separated list; the FIRST entry is canonical.
phx_hosts = Engram.HostOrigins.parse(System.get_env("PHX_HOST"))

if phx_hosts do
  scheme = System.get_env("PHX_SCHEME") || if(config_env() == :prod, do: "https", else: "http")

  url_port =
    String.to_integer(
      System.get_env("PHX_PORT") || if(config_env() == :prod, do: "443", else: "80")
    )

  config :engram, EngramWeb.Endpoint,
    url: [host: phx_hosts.canonical_host, port: url_port, scheme: scheme]
end

if config_env() == :prod do
  # Boot-time guard against shipping a release whose index.html references
  # bundle hashes that don't exist on disk (stale Docker layer cache, etc).
  # See Engram.SpaIntegrity and docs/context/docker-build-cache-pitfalls.md.
  config :engram, :spa_integrity_check_enabled, true

  # Trust Cloudflare's CF-Connecting-IP for rate-limit client-IP resolution.
  # Safe ONLY because prod enforces Cloudflare Authenticated Origin Pulls
  # (AOP `verify`), which guarantees every request transited Cloudflare. The
  # operator sets TRUST_CF_CONNECTING_IP=true in the prod ECS task def; default
  # false keeps prod on the raw socket IP until then. If AOP is ever disabled,
  # unset this. See EngramWeb.RemoteIp.
  config :engram, :trust_cf_connecting_ip, System.get_env("TRUST_CF_CONNECTING_IP") == "true"

  # Telemetry/log HMAC key for hashing user ids in metric labels + logs.
  # Distinct from any encryption key. SaaS prod + staging set this via SOPS so
  # `user_id_hmac` correlates across restarts and deployments. CI test images
  # and self-host releases that haven't wired the env var get a per-boot random
  # — telemetry hashes still don't leak plaintext ids, they just don't
  # correlate across reboots. The warning is intentional so operators notice.
  case System.get_env("TELEMETRY_HMAC_KEY_USER_ID") do
    nil ->
      require Logger

      Logger.warning(
        "TELEMETRY_HMAC_KEY_USER_ID not set; using per-boot random key " <>
          "(user_id_hmac will not correlate across restarts)"
      )

      config :engram, :hmac_key_user_id, Base.encode64(:crypto.strong_rand_bytes(32))

    key ->
      config :engram, :hmac_key_user_id, key
  end

  # Analytics-id HMAC key (Engram.Observability.PostHog.analytics_id/1).
  # Separate secret from TELEMETRY_HMAC_KEY_USER_ID above — domain separation
  # is the entire point of a keyed hash.
  case System.get_env("HMAC_KEY_ANALYTICS_ID") do
    nil ->
      # Self-host and dev: analytics is off anyway (no posthog_key), so a
      # random per-boot key is correct — it can never collide with the SaaS
      # namespace even if a key is later set. But that safety rests on an
      # unenforced coupling between two independently-read env vars, so warn
      # if POSTHOG_API_KEY IS set — this key is about to silently re-identify
      # every person in PostHog on every deploy.
      if System.get_env("POSTHOG_API_KEY") do
        require Logger

        Logger.warning(
          "HMAC_KEY_ANALYTICS_ID not set but POSTHOG_API_KEY is; using a " <>
            "per-boot random analytics-id key (every person will be re-identified on every deploy)"
        )
      end

      config :engram, :hmac_key_analytics_id, Base.encode64(:crypto.strong_rand_bytes(32))

    key ->
      config :engram, :hmac_key_analytics_id, key
  end

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # DATABASE_SSL=true enables TLS to the Postgres server (required by AWS RDS;
  # self-host local pg usually has none, so default off). Verification mode is
  # DATABASE_SSL_MODE: unset → `verify_none` (the long-standing default, kept so
  # this can't break a running deploy); `verify-full` → `verify_peer` against
  # the OS trust store with SNI + hostname check, closing the in-VPC MITM gap.
  # verify-full is opt-in: flip it once the chain is confirmed on staging.
  # See Engram.RuntimeConfig.database_ssl/2.
  #
  # Postgrex 0.20+ accepts the SSL opt list directly under `:ssl`.
  database_ssl_opts =
    Engram.RuntimeConfig.database_ssl(&System.get_env/1, URI.parse(database_url).host)

  config :engram,
         Engram.Repo,
         [
           url: database_url,
           pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
           # For machines with several cores, consider starting multiple pools of `pool_size`
           # pool_count: 4,
           socket_options: maybe_ipv6,
           # T3.0.2 — defense-in-depth. Prevents Ecto SQL params (path, folder,
           # tags, wrapped DEK on UPDATE) from hitting :debug logs if anyone
           # bumps prod log level. Audit-only; prod log level today is :info.
           log: false,
           # Idle-in-transaction and lock timeouts; see the function's doc.
           # Release.migrate strips them for the migrator.
           parameters: Engram.RuntimeConfig.repo_parameters(:app)
         ] ++ database_ssl_opts

  # Second pool, for work that legitimately spans tenants (orphan reaping,
  # expiry sweeps, credential lookups that DISCOVER a user_id). See
  # `Engram.Repo.Maintenance`.
  #
  # Unset is supported and correct for self-host: one box, one tenant,
  # connecting as its own database owner, nothing for RLS to separate. The
  # resolver `Engram.Repo.maintenance/0` then hands back `Engram.Repo` and
  # callers read identically, so a self-hoster never configures a second
  # credential and never learns this exists.
  #
  # Unset on SaaS, where the app connects as a role RLS applies to, means every
  # such sweep is filtered to zero rows and reports success.
  # `Engram.Repo.TenancyGuard` is what says so at boot.
  # `""` is matched alongside `nil` deliberately. An empty-valued env var is a
  # routine state in an ECS task definition or a SOPS-rendered env file, and it
  # is the state immediately adjacent to the supported one. Without this,
  # `Ecto.Repo.Supervisor.parse_url("")` returns `[]`, so no host and no
  # database are merged, the pool starts and cannot serve a query — and
  # `maintenance_repo_enabled` is set true, so `TenancyGuard` logs the
  # REASSURING branch ("maintenance pool configured") over an unusable pool.
  # That is exactly the false-green class this change exists to remove. The
  # same `""` filter is already the convention elsewhere in this file.
  case System.get_env("MAINTENANCE_DATABASE_URL") do
    url when url in [nil, ""] ->
      :ok

    maintenance_url ->
      config :engram,
             Engram.Repo.Maintenance,
             [
               url: maintenance_url,
               # Deliberately tiny: this pool serves a few cron jobs and never a
               # request, and connections are the scarce resource on RDS (see
               # docs/context/prod-db-connection-budget.md). It is sized per
               # NODE, like POOL_SIZE, so the fleet total is this times the task
               # count.
               pool_size: String.to_integer(System.get_env("MAINTENANCE_POOL_SIZE") || "2"),
               socket_options: maybe_ipv6,
               # Same reasoning as Engram.Repo above (T3.0.2): keep Ecto params
               # out of :debug logs if anyone raises the log level.
               log: false,
               parameters: Engram.RuntimeConfig.repo_parameters(:maintenance)
             ] ++
               Engram.RuntimeConfig.database_ssl(
                 &System.get_env/1,
                 URI.parse(maintenance_url).host
               )

      # Read by `Engram.Repo.maintenance/0`. A separate key rather than probing
      # for the repo's config, so the resolver stays a cheap app-env lookup on
      # a path that runs per sweep query.
      config :engram, :maintenance_repo_enabled, true
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  jwt_secret =
    System.get_env("JWT_SECRET") ||
      raise """
      environment variable JWT_SECRET is missing.
      """

  config :joken, default_signer: jwt_secret

  config :engram, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Rate-limiter: opt into the cluster-shared DistributedETS backend when the
  # node is part of a named cluster (DNS_CLUSTER_QUERY set — SaaS prod ECS).
  # Self-host / single-node deploys without DNS_CLUSTER_QUERY stay on the
  # per-node ETS default. DistributedETS uses PubSub broadcast to keep
  # counters eventually-consistent across the cluster; no external store needed.
  if System.get_env("DNS_CLUSTER_QUERY") do
    config :engram, EngramWeb.RateLimiter, backend: :distributed_ets
  end

  # Oban notifier: PG over distributed Erlang when clustered, saving the
  # Postgres notifier's dedicated LISTEN connection on every node. Unclustered
  # nodes (self-host, single node) keep the Postgres default, the only path
  # between them. PG sends at once rather than on commit; Engram.Oban.SafeEngine
  # re-announces a job inserted inside a transaction after it commits.
  #
  # Failure modes, none of which lose a job (jobs are rows): a node cut off
  # from the cluster hears no inserts, and its stager falls back to waking its
  # own producers every stage_interval (Notifier.status :solitary/:isolated ->
  # local mode). During the rolling deploy that switches notifiers, old and new
  # nodes cannot hear each other's notifications; a new worker that is not
  # yet leader hears inserts only from new web nodes, and picks up the rest
  # once the old worker exits and it takes leadership (Peers.Database, 30s
  # election) and stages. ObanPgNotifierTest pins this branch.
  if System.get_env("DNS_CLUSTER_QUERY") do
    config :engram, Oban, notifier: Oban.Notifiers.PG
  end

  # Node role. `queues: false` supervises no producers while leaving
  # `Oban.insert/1` fully working, so a node that holds user sockets still
  # ENQUEUES embed/index/checkpoint work but never EXECUTES it. That is the
  # whole split: `embed: 5` (peak ≈ 560 MB) and `indexing: 2` can no longer
  # take schedulers or pool connections from the node a user is typing into.
  #
  # The flag is opt-OUT, and that direction is load-bearing. Unset means "run
  # every queue", so a single-node deploy (self-host, and any SaaS node brought
  # up before the worker service exists) keeps the full list from
  # config/config.exs and behaves exactly as today. Only a node explicitly
  # marked `web` stops executing. An opt-IN flag would invert the failure: one
  # unset variable on the worker service and NOTHING in the cluster drains the
  # queues — silently, since enqueues keep succeeding.
  #
  # Web also runs no plugins, and that is what keeps it out of the leader
  # election. Cron/Pruner/Lifeline and the Stager's DB transaction run only on
  # the Oban leader, and before this a web task held leadership about 49% of
  # the time (2026-10-20 audit): leadership moved to web whenever the single
  # worker restarted and stayed there until web redeployed. In Oban 2.24,
  # `plugins: false` maps the peer to `Oban.Peers.Isolated, leader?: false`, so
  # the worker (or an unset/self-host node) is the only possible leader.
  # `Oban.insert/1` and its pg_notify are unaffected. ObanWebRolePluginsTest
  # pins both halves.
  #
  # The worker MUST share DNS_CLUSTER_QUERY with the web nodes:
  # `Workers.CheckpointNote` guards on `CrdtRegistry.lookup/1`, which is
  # `:global`. Unclustered, it cannot see a room live on a web node, stops
  # snoozing, and checkpoints a note someone has open — writing behind the
  # room's back.
  # Matched against a CLOSED SET rather than testing for "web", because the
  # opt-out direction that makes the unset case safe also makes every typo
  # silent: `WEB`, `web ` or `wbe` would all mean "run every queue" on a node
  # that was meant to run none. That is not the harmless direction it looks
  # like — the whole fleet executing is how you get a checkpoint racing a live
  # room. Case and whitespace are forgiven (an ECS task definition is
  # hand-edited); an unrecognised value is not.
  #
  # Raising is right HERE and wrong for the cluster check below: a typo is
  # static and no amount of retrying fixes it, so failing the boot is the only
  # way the operator finds out. Matches how this file already treats a missing
  # DATABASE_URL.
  case System.get_env("ENGRAM_NODE_ROLE") do
    nil ->
      :ok

    role ->
      case role |> String.trim() |> String.downcase() do
        "web" ->
          config :engram, :node_role, :web
          config :engram, Oban, queues: false, plugins: false

          # `queues: false` leaves this node unable to observe queue depth, and
          # PromEx's `:oban_queue_poll_metrics` are `last_value` gauges that
          # never expire — so a poller with nothing to poll does not go quiet,
          # it freezes and serves its final sample forever. Prod 2026-08-28:
          # web published a 494-job embed backlog for 40+ minutes against an
          # empty queue, and every dashboard and alert that selects
          # `max by (queue)` across roles read that copy instead of the
          # worker's live one. Absent beats wrong. See #1497.
          # Literal, NOT a call to Engram.PromEx.drop_metrics_groups/1. This file
          # is evaluated by a Config.Provider during release boot, before any
          # application starts; calling into app code there is a boot-crash risk
          # for no gain. PromExObanPollGroupTest asserts this literal and that
          # function stay in agreement.
          #
          # The Installs poller is dropped too: every node reads the same
          # install_pings count from the DB, so the worker's copy is enough.
          config :engram, Engram.PromEx,
            drop_metrics_groups: [:oban_queue_poll_metrics, :engram_installs_polling_metrics]

        "worker" ->
          # Recorded because DECLARING a role is what tells the boot check this
          # is a split fleet, and the unclustered *worker* is the node that can
          # actually corrupt data (see Application.warn_if_split_fleet_unclustered/0).
          config :engram, :node_role, :worker

          # The ONLY queue that differs from the unsplit default, and it belongs
          # here rather than in config/config.exs because it is only safe on a
          # node shaped like this one. A worker never binds a CRDT room, so it
          # never runs the inline CheckpointGate (3) that a web or unsplit node
          # spends alongside this lane — and its POOL_SIZE is 25, not 15. Both
          # halves of that are what make 6 affordable.
          #
          # 6 restores the capacity the cluster already had: the lane used to run
          # on BOTH web nodes (2 x 3), so consolidating it onto one worker at 3
          # would have halved overflow throughput for exactly the reconnect storm
          # the lane exists to absorb.
          #
          # Partial `queues:` overrides deep-merge into the base keyword list
          # (Config merges nested keyword lists), so the other queues are
          # untouched. ObanQueueConfigTest pins that behaviour — if it ever
          # became a wholesale replace, the worker would boot with
          # crdt_checkpoint as its only queue and embedding would stop.
          config :engram, Oban, queues: [crdt_checkpoint: 6]

        "" ->
          :ok

        other ->
          raise "ENGRAM_NODE_ROLE must be \"web\" or \"worker\", got: #{inspect(other)}"
      end
  end

  config :engram, EngramWeb.Endpoint,
    http: [
      # Enable IPv6 and bind on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      thousand_island_options: [shutdown_timeout: 30_000]
    ],
    secret_key_base: secret_key_base

  # CORS and WebSocket origin — only lock down when PHX_HOST is explicitly set.
  # Without it, defaults apply: CORS allows "*", WS allows all. That permissive
  # default is fine for self-host (single-tenant, same-origin), but a saas
  # deploy (AUTH_PROVIDER=clerk) MUST have PHX_HOST or it would answer
  # Access-Control-Allow-Origin: * and accept any WS Origin — so we fail closed
  # there (see Engram.RuntimeConfig.validate_saas_origins!/2).
  # See Engram.HostOrigins for parsing rules (CSV, scheme expansion, dedup).
  #
  # ENGRAM_SAAS_FRONTEND_ORIGINS appends extra origins (comma-separated) for the
  # Cloudflare Pages saas frontend at app.engram.page + its preview deploys at
  # *.engram-frontend.pages.dev. Unset on selfhost (same-origin) → no-op.
  Engram.RuntimeConfig.validate_saas_origins!(
    auth_provider,
    phx_hosts,
    System.get_env("CI") == "true"
  )

  if phx_hosts do
    extra_origins =
      case System.get_env("ENGRAM_SAAS_FRONTEND_ORIGINS") do
        nil ->
          []

        "" ->
          []

        s ->
          s
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end

    cors_origins = phx_hosts.origins ++ extra_origins
    config :engram, :cors_origin, cors_origins
    config :engram, :websocket_check_origin, cors_origins
  end

  # Hosted MCP gateways whose Worker sends an Origin, e.g.
  # `https://smithery.ai,https://*.run.tools`. Read only by McpOriginGuard; see
  # the comment on `gateway?/1` there. Unset → [] → no change in behavior.
  config :engram,
         :mcp_gateway_origins,
         (System.get_env("MCP_GATEWAY_ORIGINS") || "")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))

  # Host-driven path rewrite for the dedicated `api.engram.page` and
  # `mcp.engram.page` saas hosts. Opt-in: selfhost releases (and the
  # current `app.engram.page` host until DNS cutover) leave this unset
  # and the plug is a strict no-op. See EngramWeb.Plugs.HostRewrite.
  if System.get_env("ENGRAM_HOST_REWRITE_ENABLED") == "true" do
    saas_only? = System.get_env("ENGRAM_SAAS_ONLY") == "true"

    extra_hosts =
      case System.get_env("ENGRAM_ALLOWED_EXTRA_HOSTS") do
        nil -> []
        "" -> []
        s -> String.split(s, ",", trim: true)
      end

    config :engram, :host_rewrite,
      api_host: "api.engram.page",
      mcp_host: "mcp.engram.page",
      reject_unknown_hosts: saas_only?,
      allowed_extra_hosts: extra_hosts
  end

  # Token OpenAI's plugin portal issues for domain verification; served at
  # /.well-known/openai-apps-challenge. See EngramWeb.WellKnownController.
  if token = System.get_env("OPENAI_APPS_CHALLENGE") do
    config :engram, :openai_apps_challenge, String.trim(token)
  end

  # Absolute base URL of the frontend (SPA) host. After the saas eject the SPA
  # lives on a different origin (app.engram.page) than the backend it reaches
  # on api./mcp.engram.page, so the OAuth /authorize flow must 302 the consent
  # page there absolutely instead of relative. Unset on self-host (same-origin
  # → relative redirect). See EngramWeb.OAuthAuthorizeController.redirect_to_spa.
  if url = System.get_env("ENGRAM_FRONTEND_URL") do
    config :engram, :frontend_base_url, url
  end

  # No `https:`/`force_ssl` endpoint config by design: TLS terminates at the
  # edge (ALB in SaaS prod, the operator's reverse proxy in self-host) and the
  # app only ever listens plaintext on PORT behind it.
end

# Bearer token guarding the PromEx /metrics scrape endpoint. The Grafana
# Agent sidecar (engram-infra observability.tf) injects the same token
# from SOPS-encrypted prod secrets (`metrics_auth_token`). The plug
# (EngramWeb.Plugs.MetricsAuth) fails closed when this is unset, so dev
# and self-host implicitly disable the endpoint without code changes.
if token = System.get_env("METRICS_AUTH_TOKEN") do
  config :engram, :metrics_auth_token, token
end

# Sentry error reporting. No-op when SENTRY_DSN is unset (dev/test
# and self-host), so the only thing needed to opt in is setting the
# env var. SaaS prod injects it via ECS SSM SecureString sourced from
# SOPS (`sentry_dsn_backend`); follow-up engram-infra PR wires the
# `aws_ssm_parameter` and `ecs_secrets.tf` mapping.
if dsn = System.get_env("SENTRY_DSN") do
  # `release` MUST equal what `getsentry/action-release@v3` registers in
  # verify.yml — currently `version: ${{ github.sha }}` (full 40-char
  # commit SHA). Frontend Sentry SDK uses the same value via VITE_GIT_SHA
  # at build time. Backend ECS injects RELEASE_SHA from
  # `var.engram_release_sha` (engram-infra) so all three sources agree
  # on the same string and the Sentry "Releases" view + suspect-commits
  # + cross-event grouping work.
  #
  # Empty-string would register events under release "" — a real Sentry
  # release that clutters the picker — so coerce blank → nil to mirror
  # the "unset" semantic.
  release =
    case System.get_env("RELEASE_SHA") do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end

  config :sentry,
    dsn: dsn,
    environment_name: to_string(config_env()),
    enable_source_code_context: true,
    root_source_code_paths: [File.cwd!()],
    release: release,
    tags: %{env: to_string(config_env())},
    # Tracing off in Tier 1 — OpenTelemetry → Tempo lands in Tier 2 with
    # a 10% sample rate. Setting traces_sample_rate: nil makes Sentry
    # ignore transaction telemetry entirely.
    traces_sample_rate: nil
end

# PostHog server-side capture (Engram.Observability.PostHog).
# Same opt-in shape as Sentry: no-op when POSTHOG_API_KEY is unset,
# so dev/test/self-host emit no telemetry and the wrapper module
# short-circuits before any network call. distinct_id matches the
# frontend's posthog.identify(clerk_user_id) so funnels join across
# the user timeline.
if key = System.get_env("POSTHOG_API_KEY") do
  config :engram,
    posthog_key: key,
    posthog_host: System.get_env("POSTHOG_HOST", "https://us.i.posthog.com")
end

# PostHog erasure (Engram.Observability.PostHog.delete_person/1), called from
# account hard-delete (GDPR Art. 17). Deliberately a SEPARATE key from
# POSTHOG_API_KEY above: that one is capture-only and must stay read-only;
# person-delete needs person:write scope. admin_config/0 no-ops when either
# var is unset (self-host, dev).
config :engram,
  posthog_erasure_api_key: System.get_env("POSTHOG_ERASURE_API_KEY"),
  posthog_project_id: System.get_env("POSTHOG_PROJECT_ID")

# Pyroscope continuous CPU profiling. Same opt-in shape as Sentry/PostHog:
# the worker's child_spec/1 returns :ignore when any of the three required
# env vars is missing, so dev/test/self-host emit no profiling traffic and
# the supervisor silently drops the child from the start order.
#
# Wired infra-side via engram-infra/main/envs/prod/ecs_secrets.tf:
#   GRAFANA_PYROSCOPE_URL       → grafana_pyroscope_url       (SOPS)
#   GRAFANA_PYROSCOPE_USERNAME  → grafana_pyroscope_username  (SOPS)
#   GRAFANA_AGENT_TOKEN         → grafana_agent_token         (SOPS)
# (The token is shared with Loki/Tempo/Prom remote_write — same Grafana
#  Cloud access policy, scoped to "metrics:write logs:write traces:write
#  profiles:write".)
if pyroscope_url = System.get_env("GRAFANA_PYROSCOPE_URL") do
  config :engram, :pyroscope,
    url: pyroscope_url,
    username:
      System.get_env("GRAFANA_PYROSCOPE_USERNAME") ||
        raise("GRAFANA_PYROSCOPE_USERNAME required when GRAFANA_PYROSCOPE_URL is set"),
    token:
      System.get_env("GRAFANA_AGENT_TOKEN") ||
        raise("GRAFANA_AGENT_TOKEN required when GRAFANA_PYROSCOPE_URL is set"),
    app_name: System.get_env("PYROSCOPE_APP_NAME", "engram-saas-prod"),
    env: to_string(config_env()),
    instance: System.get_env("HOSTNAME", System.get_env("ECS_TASK_ID", "unknown")),
    sample_interval_ms:
      Engram.Observability.Pyroscope.parse_interval_ms(
        System.get_env("PYROSCOPE_SAMPLE_INTERVAL_MS"),
        10
      ),
    push_interval_ms:
      Engram.Observability.Pyroscope.parse_interval_ms(
        System.get_env("PYROSCOPE_PUSH_INTERVAL_MS"),
        10_000
      )
end

# OpenTelemetry tracing. Same opt-in shape as Sentry/Pyroscope: no-op
# unless the OTLP endpoint is set (prod points it at the Alloy sidecar
# on loopback; Alloy forwards to Tempo). ENGRAM_OTEL_SAMPLE_RATIO tunes
# head sampling without a code deploy (1.0 = every trace).
#
# The root sampler drops health-check / scrape traffic outright (~96% of
# span volume — see Engram.Observability.TraceSampler), then delegates the
# rest to the ratio sampler. Under :parent_based a root :drop cascades, so
# probe traces never build child spans or hit Tempo.
if otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
  ratio = Engram.Observability.Otel.sample_ratio(System.get_env("ENGRAM_OTEL_SAMPLE_RATIO"), 1.0)

  # SpanScrubber MUST precede the exporting processor: its on_start rewrites
  # the span (route template, no query, truncated IPs) before it is recorded.
  config :opentelemetry,
    processors: [
      {Engram.Observability.SpanScrubber, %{}},
      {:otel_batch_processor, %{}}
    ],
    traces_exporter: :otlp,
    sampler: {:parent_based, %{root: {Engram.Observability.TraceSampler, %{ratio: ratio}}}},
    resource: [
      service: [name: "engram-backend"],
      deployment: [environment: to_string(config_env())]
    ]

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: otlp_endpoint
end

# Note version history (#1710). See config.exs for why prod defaults off.
if config_env() == :prod do
  config :engram, :history_recording, System.get_env("HISTORY_RECORDING", "false") == "true"
end

if gap = System.get_env("HISTORY_SESSION_GAP_MINUTES") do
  minutes = String.to_integer(gap)

  # 0 would start a new version on every save; a negative gap is meaningless.
  if minutes < 1 do
    raise "HISTORY_SESSION_GAP_MINUTES must be at least 1, got: #{inspect(gap)}"
  end

  config :engram, :history_session_gap_minutes, minutes
end
