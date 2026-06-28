import Config

# Raise rate-limit ceiling in tests so auth controller tests don't get 429.
# All test connections share 127.0.0.1 as remote_ip; a production-level limit
# of 10 req/min would be exhausted immediately across the full test suite.
# The RateLimitTest validates the 10-req limit explicitly, with per-test resets.
config :engram, :rate_limit_override, 10_000

# Same rationale for the pre-auth (vault-pipeline) limiter: it now covers
# every vault path, so without a high ceiling the shared 127.0.0.1 test IP
# would accumulate across ConnCase tests and flake on 429. The dedicated
# PreAuthRateLimitTest sets its own low override per-test to exercise limits.
config :engram, :pre_auth_rate_limit_override, 10_000

# T3.5.5 / M3 — boot canary disabled in tests; supervisor start runs
# before sandbox checkout, and the canary table is per-sandbox. Tests
# cover BootCanary directly via Engram.Crypto.BootCanaryTest.
config :engram, :boot_canary_enabled, false

# #619 — bootstrap admin advisory lock disabled in tests. It's a global
# pg_advisory_xact_lock; under the SQL sandbox (one transaction per test) it's
# held for the whole test and deadlocks once enough user-creating tests run
# async. Role assignment stays correct via the row-based bootstrap_pending?
# check; the lock only guards true-concurrent first-signups, which can't happen
# across isolated sandbox transactions. Prod keeps it (defaults true).
config :engram, :admin_bootstrap_lock_enabled, false

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

config :engram,
       Engram.Repo,
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

# Use mock AWS KMS client in tests — never hits the network
config :engram, :aws_kms_client, Engram.AwsKmsMock

# Use mock embedder in tests — never hits Voyage AI
config :engram, :embedder, Engram.MockEmbedder

# Qdrant config for tests — disable retries so fire-and-forget Tasks
# (e.g. Notes.delete_note → Indexing.delete_note_index) fail fast and
# silently instead of retrying 3x with noisy warnings against localhost:6333.
# Tests that need real Qdrant interaction use Bypass and override :qdrant_url.
config :engram, :qdrant_collection, "engram_notes"
config :engram, :qdrant_retry, false

# Use in-memory ETS storage in tests — no DB I/O, no S3 required
config :engram, :storage, Engram.Storage.InMemory

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

# Paddle — sandbox fixtures, no live network calls. Client behaviour is Mox-mocked.
config :engram, :paddle_api_key, "pdl_apns_test_fake"
config :engram, :paddle_notification_secret, "pdl_ntfn_test_fake"
config :engram, :paddle_client_token, "live_token_test_fake"
config :engram, :paddle_starter_monthly_price_id, "pri_starter_monthly_test"
config :engram, :paddle_starter_annual_price_id, "pri_starter_annual_test"
config :engram, :paddle_pro_monthly_price_id, "pri_pro_monthly_test"
config :engram, :paddle_pro_annual_price_id, "pri_pro_annual_test"
config :engram, :paddle_env, "sandbox"
config :engram, :paddle_client, Engram.Paddle.ClientMock

# Clerk webhook — svix-style HMAC signing. Secret is base64 of "clerk-test-secret"
# (prefix `whsec_` is stripped before decoding per svix spec).
config :engram, :clerk_webhook_secret, "whsec_Y2xlcmstdGVzdC1zZWNyZXQ="
config :engram, :clerk_secret_key, "sk_test_fake_clerk_backend_api"
config :engram, :clerk_api, Engram.Auth.Clerk.ApiMock

# Email — tests configure with a Mox; default to NoOp for tests that don't
# care about email delivery.
config :engram, :email_provider, Engram.Email.NoOp

# Resend webhook — svix-style HMAC signing (same scheme as Clerk). Secret is
# base64 of "resend-test-secret" with the `whsec_` prefix per svix spec.
config :engram, :resend_webhook_secret, "whsec_#{Base.encode64("resend-test-secret")}"

# Default to local auth provider in tests
config :engram, :auth_provider, :local

# Stable test master key — 32 bytes of 0xAB, base64-encoded
config :engram,
  key_provider: Engram.Crypto.KeyProvider.Local,
  encryption_master_key: Base.encode64(:binary.copy(<<0xAB>>, 32))

# Onboarding wizard defaults for tests. Individual tests can override
# via Application.put_env/3 in their setup blocks.
config :engram, :billing_enabled, true

# Limits enforced by default in test env so existing tests don't bypass.
config :engram, :limits_enforced, true

# Legal seeder skipped at boot in tests — SeederTest seeds per-case.
config :engram, :seed_legal_on_boot, false
