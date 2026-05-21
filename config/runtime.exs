import Config

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
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() != :test do
  # Storage backend — S3-compatible only (A.5, PR #62). The legacy BYTEA
  # `Storage.Database` adapter is gone; STORAGE_BACKEND is informational and
  # only "s3" is accepted (default).
  case System.get_env("STORAGE_BACKEND", "s3") do
    "s3" ->
      config :engram, :storage, Engram.Storage.S3
      config :engram, :storage_bucket, System.get_env("STORAGE_BUCKET", "engram-attachments")

      config :ex_aws,
        access_key_id: System.get_env("STORAGE_ACCESS_KEY_ID"),
        secret_access_key: System.get_env("STORAGE_SECRET_ACCESS_KEY"),
        region: System.get_env("STORAGE_REGION", "auto")

      config :ex_aws, :s3,
        scheme: System.get_env("STORAGE_SCHEME", "https://"),
        host: System.get_env("STORAGE_HOST"),
        port: String.to_integer(System.get_env("STORAGE_PORT", "443"))

    other ->
      raise """
      Unknown STORAGE_BACKEND=#{inspect(other)} — only \"s3\" is supported
      since A.5 (PR #62). The BYTEA Storage.Database adapter was removed
      along with the `attachments.content` column.
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

  if System.get_env("QDRANT_URL") do
    config :engram, :qdrant_url, System.get_env("QDRANT_URL")
  end

  if System.get_env("QDRANT_COLLECTION") do
    config :engram, :qdrant_collection, System.get_env("QDRANT_COLLECTION")
  end

  if qdrant_api_key = System.get_env("QDRANT_API_KEY") do
    config :engram, :qdrant_api_key, qdrant_api_key
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

# Auth provider selection: "local" (built-in email/password) or "clerk" (SaaS JWKS)
# Default: local — self-hosters get working auth with zero third-party config.
auth_provider =
  case System.get_env("AUTH_PROVIDER", "local") do
    "local" -> :local
    "clerk" -> :clerk
    other -> raise "Invalid AUTH_PROVIDER=#{other}. Valid values: local, clerk"
  end

config :engram, :auth_provider, auth_provider

# Email transactional provider (pricing v2 §C). Default: NoOp for self-host;
# Resend when RESEND_API_KEY is set.
if api_key = System.get_env("RESEND_API_KEY") do
  config :engram, :email_provider, Engram.Email.Resend
  config :engram, :resend_api_key, api_key
end

if email_from = System.get_env("EMAIL_FROM") do
  config :engram, :email_from, email_from
end

# Rate limit override for CI E2E tests (only effective when CI=true).
# Production deploys never set CI=true, so this is unreachable in prod.
if override = System.get_env("RATE_LIMIT_AUTH_OVERRIDE") do
  config :engram, :rate_limit_auth_override, String.to_integer(override)
end

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
end

# Pricing v2 §A — phone-verification gate on EmbedNote worker. Default off so
# self-host and pre-launch cloud aren't affected. Cloud ops flips to "true"
# when ready to enforce.
if System.get_env("REQUIRE_PHONE_FOR_EMBED") in ["1", "true"] do
  config :engram, :require_phone_for_embed, true
end

# Pricing v2 §G — sync channel realtime_sync_enabled gate. Default off so
# pre-v2-launch Free users keep their realtime sync. Cloud ops flips to
# "true" on launch day; Free users joining sync:* get
# %{reason: "channel_forbidden_on_plan"}.
if System.get_env("REALTIME_SYNC_GATE_ENABLED") in ["1", "true"] do
  config :engram, :realtime_sync_gate_enabled, true
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

  config :engram, :paddle_starter_price_id, System.get_env("PADDLE_STARTER_PRICE_ID")
  config :engram, :paddle_pro_price_id, System.get_env("PADDLE_PRO_PRICE_ID")
  config :engram, :paddle_env, System.get_env("PADDLE_ENV", "sandbox")
end

# Onboarding wizard toggle. Active when Paddle API key is set (SaaS mode);
# disabled in self-host (no PADDLE_API_KEY → no payment → no wizard).
config :engram, :billing_enabled, System.get_env("PADDLE_API_KEY") != nil

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
        System.get_env("PADDLE_API_KEY") != nil

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

# Current Terms of Service version. Must match the version exported by
# frontend/src/legal/terms-of-service.tsx. Bumping this re-prompts every
# user on next request via the RequireOnboarding plug.
config :engram, :current_tos_version, System.get_env("CURRENT_TOS_VERSION", "2026-05-15")

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

    # Scoped to :ex_aws, :kms so we don't overwrite the global :ex_aws creds
    # that the S3 storage backend (Fly Tigris) configured above with
    # STORAGE_ACCESS_KEY_ID/STORAGE_SECRET_ACCESS_KEY/STORAGE_REGION.
    config :ex_aws, :kms,
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      region: System.fetch_env!("AWS_REGION")
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

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :engram, Engram.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6,
    # T3.0.2 — defense-in-depth. Prevents Ecto SQL params (path, folder,
    # tags, wrapped DEK on UPDATE) from hitting :debug logs if anyone
    # bumps prod log level. Audit-only; prod log level today is :info.
    log: false

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

  config :engram, EngramWeb.Endpoint,
    http: [
      # Enable IPv6 and bind on all interfaces.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # CORS and WebSocket origin — only lock down when PHX_HOST is explicitly set.
  # Without it (CI, local dev), defaults apply: CORS allows "*", WS allows all.
  # See Engram.HostOrigins for parsing rules (CSV, scheme expansion, dedup).
  if phx_hosts do
    config :engram, :cors_origin, phx_hosts.origins
    config :engram, :websocket_check_origin, phx_hosts.origins
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :engram, EngramWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :engram, EngramWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
