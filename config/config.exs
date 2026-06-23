# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :engram,
  ecto_repos: [Engram.Repo],
  generators: [timestamp_type: :utc_datetime],
  env: Mix.env()

# Configure the endpoint
config :engram, EngramWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: EngramWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Engram.PubSub,
  live_view: [signing_salt: "tdOwl/mL"]

# WebSocket origin check: false because Obsidian uses app:// scheme which
# Phoenix can't validate. Channel auth (JWT) is the real security boundary.
config :engram, :websocket_check_origin, false

# Client-IP resolution for rate limiting. Default-deny: only trust the
# Cloudflare `CF-Connecting-IP` header where a verified proxy guarantees it
# (prod, which enforces Cloudflare Authenticated Origin Pulls). Dev, test,
# self-host, and staging-fastraid are NOT behind Cloudflare+AOP, so they fall
# back to the raw socket IP. Flipped on in prod via runtime.exs + the
# TRUST_CF_CONNECTING_IP env var. See EngramWeb.RemoteIp.
config :engram, :trust_cf_connecting_ip, false

# PromEx — collects BEAM / Phoenix / Ecto / Oban metrics for the Prom-format
# /metrics endpoint scraped by the Grafana Agent sidecar in prod. We disable
# the bundled metrics_server (we mount via the router with bearer auth) and
# Grafana dashboard uploads (managed via Terraform-as-code, not runtime).
config :engram, Engram.PromEx,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: :disabled,
  metrics_server: :disabled

# Embedder adapter (overridden per environment)
config :engram, :embedder, Engram.Embedders.Voyage

# Storage adapter — S3-compatible object storage (MinIO local, AWS S3 prod).
config :engram, :storage, Engram.Storage.S3

# Oban job queue (per-env overrides in dev/test/prod configs)
config :engram, Oban,
  engine: Oban.Engines.Basic,
  repo: Engram.Repo,
  # Staging poll cadence (default 1s). Fresh inserts dispatch instantly via the
  # Postgres notifier (pg_notify), which also fans out across our unclustered
  # prod nodes through the shared DB — so this poll only paces promotion of
  # scheduled/retry jobs and acts as a missed-notify safety net. 5s trims ~80%
  # of the source-less BEGIN/COMMIT/SELECT staging churn with no fresh-insert
  # latency cost.
  stage_interval: :timer.seconds(5),
  queues: [
    embed: 5,
    reindex: 1,
    maintenance: 2,
    crypto_backfill: 1,
    export: 1,
    cleanup: 1,
    indexing: 2,
    default: 1
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 3600},
    Oban.Plugins.Lifeline,
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", Engram.Workers.ReconcileEmbeddings},
       {"0 * * * *", Engram.Workers.CleanupDeviceAuthWorker},
       {"0 2 * * *", Engram.Billing.Workers.PaddleReconcile},
       {"0 3 * * *", Engram.Billing.Workers.OverrideExpirySweep},
       {"30 3 * * *", Engram.Workers.InactivityCleanup},
       {"0 4 * * *", Engram.Workers.OriginAbuseSweep},
       # Cross-store orphan sweep — weekly safety net for failed
       # event-driven Qdrant/S3 deletes. Sun 05:00 UTC, off-peak.
       {"0 5 * * 0", Engram.Workers.OrphanSweep}
     ]}
  ]

# Configure Elixir's Logger.
#
# `metadata:` declares which keys are emitted in formatter output. Credo's
# `Warning.MissedMetadataKeyInLoggerConfig` check fails for any structured
# metadata key passed to Logger.* without being listed here. New metadata
# keys must be added to this list (and any per-env override in
# config/runtime.exs / config/prod.exs).
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :attachment_id,
    :attempt,
    :body_size,
    :cap,
    :category,
    :clerk_user_id,
    :client_version,
    :column,
    :drift_kind,
    :duration_ms,
    :error_kind,
    :event_id,
    :event_type,
    :exception,
    :exception_struct,
    :failed_count,
    :family_id,
    :field,
    :first_reason,
    :job_id,
    :kind,
    :loki_ship,
    :max_attempts,
    :message,
    :method,
    :module,
    :mtls_clientcert_subject,
    :new_dek_version,
    :normalized_email_hash,
    :note_id,
    :paddle_price_id,
    :paddle_subscription_id,
    :payload_keys,
    :phase,
    :prefix,
    :price_id,
    :qdrant_id,
    :queue,
    :reason,
    :reason_label,
    :request_id,
    :request_path,
    :request_query,
    :result,
    :retry_reason,
    :route,
    :row_id,
    :server_version,
    :status,
    :storage_key,
    :table,
    :total_count,
    :user_id,
    :vault_id,
    :worker
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Key provider defaults (overridden by runtime.exs via env vars)
config :engram,
  key_provider: Engram.Crypto.KeyProvider.Local,
  dek_cache_ttl_ms: 3_600_000

# T3.5.5 / M3 — boot canary verification. Default on; tests disable to
# avoid sandbox-checkout coupling at supervisor start.
config :engram, :boot_canary_enabled, true

# Rate limiter backend. Default :ets (per-node, no deps — self-host/dev/test).
# SaaS clustered prod flips to :distributed_ets in runtime.exs when
# DNS_CLUSTER_QUERY is set (cluster-shared via PubSub broadcast).
config :engram, EngramWeb.RateLimiter, backend: :ets

# Telemetry/log HMAC key for hashing user ids (Engram.Crypto.HMAC).
# Throwaway default for dev/test; prod overrides via runtime.exs from a
# high-entropy secret. NOT an encryption key — used only to obscure user
# identifiers in metric labels and log lines.
config :engram, :hmac_key_user_id, "dev-hmac-key-do-not-use-in-prod"

# Sentry PII scrubber. Compile-time so it applies wherever Sentry captures,
# including the no-DSN dev/test case if a future test exercises a Sentry stub.
# DSN, release tag, environment_name, and source-context flags live in
# runtime.exs (gated on SENTRY_DSN).
config :sentry,
  context_lines: 5,
  before_send: {Engram.Sentry.Scrubber, :scrub}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
