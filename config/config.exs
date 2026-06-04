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

# Embedder adapter (overridden per environment)
config :engram, :embedder, Engram.Embedders.Voyage

# Storage adapter — S3-compatible object storage (MinIO local, Tigris prod).
config :engram, :storage, Engram.Storage.S3

# Oban job queue (per-env overrides in dev/test/prod configs)
config :engram, Oban,
  engine: Oban.Engines.Basic,
  repo: Engram.Repo,
  queues: [embed: 5, reindex: 1, maintenance: 2, crypto_backfill: 1],
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
    :column,
    :drift_kind,
    :duration_ms,
    :event_id,
    :event_type,
    :exception,
    :exception_struct,
    :field,
    :job_id,
    :kind,
    :max_attempts,
    :message,
    :method,
    :new_dek_version,
    :normalized_email_hash,
    :paddle_price_id,
    :paddle_subscription_id,
    :payload_keys,
    :phase,
    :price_id,
    :qdrant_id,
    :queue,
    :reason,
    :reason_label,
    :request_id,
    :request_path,
    :request_query,
    :result,
    :row_id,
    :status,
    :storage_key,
    :table,
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

# Rate limiter backend. Default ETS (per-node, single-node correct, no deps).
# SaaS prod flips to :redis in runtime.exs when REDIS_URL is set (cluster-shared).
config :engram, EngramWeb.RateLimiter, backend: :ets

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
