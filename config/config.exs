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

# Storage adapter (database = BYTEA in Postgres, s3 = MinIO/Tigris)
config :engram, :storage, Engram.Storage.Database

# Hammer rate limiting (ETS backend)
config :hammer,
  backend:
    {Hammer.Backend.ETS,
     [
       # 1 hour bucket expiry
       expiry_ms: 60_000 * 60,
       # cleanup every 2 min
       cleanup_interval_ms: 60_000 * 2
     ]}

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
       {"0 * * * *", Engram.Workers.CleanupDeviceAuthWorker}
     ]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Stripe billing
config :stripity_stripe, api_key: "sk_test_placeholder"

# Tailwind CSS (marketing pages only — React SPA uses its own Tailwind via Vite)
config :tailwind,
  version: "4.1.4",
  marketing: [
    args: ~w(
      --input=assets/css/marketing.css
      --output=priv/static/css/marketing.css
      --config=assets/tailwind.config.js
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Key provider defaults (overridden by runtime.exs via env vars)
config :engram,
  key_provider: Engram.Crypto.KeyProvider.Local,
  dek_cache_ttl_ms: 3_600_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
