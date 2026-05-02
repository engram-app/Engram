import Config

# Raise rate-limit ceiling in tests so auth controller tests don't get 429.
# All test connections share 127.0.0.1 as remote_ip; a production-level limit
# of 10 req/min would be exhausted immediately across the full test suite.
# The RateLimitTest validates the 10-req limit explicitly, with per-test resets.
config :engram, :rate_limit_override, 10_000

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
repo_opts =
  case System.get_env("DATABASE_URL") do
    nil ->
      [
        username: "engram",
        password: "engram",
        hostname: "localhost",
        database: "engram_test#{System.get_env("MIX_TEST_PARTITION")}"
      ]

    url ->
      [url: url]
  end

config :engram, Engram.Repo,
  Keyword.merge(repo_opts,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2
  )

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :engram, EngramWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "JBTH+ZYHTDIRrr+N6s2ooO4ckeuJvolFrrF3N5KuC8vU75YeOgmr2beGWxrZq3Qi",
  server: false

# Use mock embedder in tests — never hits Voyage AI
config :engram, :embedder, Engram.MockEmbedder

# Qdrant config for tests — disable retries so fire-and-forget Tasks
# (e.g. Notes.delete_note → Indexing.delete_note_index) fail fast and
# silently instead of retrying 3x with noisy warnings against localhost:6333.
# Tests that need real Qdrant interaction use Bypass and override :qdrant_url.
config :engram, :qdrant_collection, "engram_notes"
config :engram, :qdrant_retry, false

# Use real database storage in tests (backward-compatible default)
config :engram, :storage, Engram.Storage.Database

# Disable Oban queues/plugins in test — jobs must be triggered explicitly via perform_job/2
# Use Oban.Testing.with_testing_mode(:inline, fn -> ... end) in tests that need inline execution
config :engram, Oban, testing: :manual

# JWT signing secret (Joken)
config :joken, default_signer: "test-jwt-secret"

# joken_jwks: use Erlang's built-in httpc adapter (no hackney required in tests)
config :tesla, JokenJwks.HttpFetcher, adapter: Tesla.Adapter.Httpc

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Clerk auth — disabled by default in tests.
# Individual tests that need Clerk start their own ClerkStrategy via start_supervised!
# and set these values in setup blocks.
config :engram, :clerk_jwks_url, nil
config :engram, :clerk_issuer, nil

# Stripe — disabled in tests, use Mox
config :stripity_stripe, api_key: "sk_test_fake"
config :engram, :stripe_webhook_secret, "whsec_test_fake"
config :engram, :stripe_starter_price_id, "price_starter_test"
config :engram, :stripe_pro_price_id, "price_pro_test"

# Default to local auth provider in tests
config :engram, :auth_provider, :local

# Stable test master key — 32 bytes of 0xAB, base64-encoded
config :engram,
  key_provider: Engram.Crypto.KeyProvider.Local,
  encryption_master_key:
    Base.encode64(:binary.copy(<<0xAB>>, 32))
