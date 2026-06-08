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
  # Storage backend. Default "s3" is the SaaS/prod path (Fly Tigris) and the
  # standard self-host path (MinIO). "database" is a self-host-only convenience
  # (#297) that stores attachment bytes in Postgres `bytea` so a minified stack
  # can drop MinIO — not for scale (that's why BYTEA was removed for SaaS in
  # A.5/PR #62); it stores opaque ciphertext in a generic `storage_objects`
  # table, NOT the old `attachments.content` column.
  case System.get_env("STORAGE_BACKEND", "s3") do
    "s3" ->
      config :engram, :storage, Engram.Storage.S3
      config :engram, :storage_bucket, System.get_env("STORAGE_BUCKET", "engram-attachments")

      # Explicit static creds (Tigris, MinIO, self-host) — only set
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

      # Endpoint override (Tigris, MinIO) — only when STORAGE_HOST is
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
      "s3" (default; SaaS Tigris / self-host MinIO) and "database"
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

  # Voyage 429 → snooze duration (seconds). Tune as Voyage RPM grows: lower
  # values churn jobs faster once budget is restored; higher values are gentler
  # on a small bucket. Default 60s suits both free-tier (3 RPM) and paid.
  if secs = System.get_env("EMBED_429_SNOOZE_SECONDS") do
    config :engram, :embed_429_snooze_seconds, String.to_integer(secs)
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
       System.get_env("ENGRAM_UPGRADE_URL", "https://app.engram.page/settings/billing")

# Email transactional provider (pricing v2 §C). Default: NoOp for self-host;
# Resend when RESEND_API_KEY is set.
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

  # Waitlist mode mirrors the Clerk Dashboard sign-up mode (Restrictions →
  # Waitlist). The dashboard flag is the actual gate — Clerk's API rejects
  # non-approved signups regardless of frontend. This var only adjusts the
  # SPA UI: replaces the "Sign up" CTA with a /waitlist route and tells
  # <SignIn /> where the waitlist lives (Clerk requires waitlistUrl). Keep
  # in sync with the dashboard; flipping one without the other = broken UX
  # but never an open signup hole.
  if System.get_env("CLERK_WAITLIST_MODE") in ["1", "true"] do
    config :engram, :clerk_waitlist_mode, true
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

# Pricing v2 §H — attachment MIME / extension whitelist self-host knobs.
# Default: gate is ON. Operators who want to allow executables (e.g.
# distributing an internal tool from a self-hosted vault) set
# ATTACHMENT_MIME_BYPASS=true. To extend the allowlist with a couple of
# extra MIMEs without disabling the gate, use
# ATTACHMENT_MIME_ALLOWLIST_EXTRA=mime1,mime2.
if System.get_env("ATTACHMENT_MIME_BYPASS") in ["1", "true"] do
  config :engram, :attachment_mime_bypass, true
end

if extras = System.get_env("ATTACHMENT_MIME_ALLOWLIST_EXTRA") do
  list =
    extras
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  if list != [], do: config(:engram, :attachment_mime_allowlist_extra, list)
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
    # :ex_aws creds that the S3 storage backend (Fly Tigris / MinIO)
    # may have configured above.
    #
    # Explicit static creds (Fly with an AWS access key for KMS, local
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

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # DATABASE_SSL=true enables TLS to the Postgres server. Required by
  # AWS RDS (pg_hba.conf rejects "no encryption" connections);
  # self-host MinIO/local Postgres typically has no SSL configured so
  # default is false. `verify: :verify_none` skips peer cert chain
  # validation — the RDS root CA isn't bundled into the Alpine image
  # and traffic is already inside the prod VPC, so peer auth adds no
  # meaningful confidentiality beyond what TLS-on-the-wire provides.
  #
  # Postgrex 0.20+ accepts the SSL opt list directly under `:ssl` (a
  # keyword list both enables TLS and supplies the opts); the older
  # `:ssl_opts` companion key was deprecated and emits one
  # `:ssl_opts is deprecated, pass opts to :ssl instead` warning per
  # connection start.
  database_ssl_opts =
    if System.get_env("DATABASE_SSL") in ~w(true 1) do
      [ssl: [verify: :verify_none]]
    else
      []
    end

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
           log: false
         ] ++ database_ssl_opts

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

  # Rate-limiter: opt into the cluster-shared Redis backend only when a store
  # URL is provided (SaaS prod, ElastiCache — engram-infra#158). Self-host /
  # any deploy without REDIS_URL stays on the per-node ETS default. The Redis
  # limiter fails open + alerts if the store is unreachable (see RateLimiter).
  if redis_url = System.get_env("REDIS_URL") do
    config :engram, EngramWeb.RateLimiter, backend: :redis

    # `:url` is the only valid runtime start option for the Hammer.Redis backend
    # (Redix rejects unknown start keys). The key prefix and command timeout are
    # compile-time `use Hammer` opts on the limiter module — see start_opts/1.
    config :engram,
           EngramWeb.RateLimiter.Redis,
           EngramWeb.RateLimiter.Redis.start_opts(redis_url)

    # Same opt-in for the per-user caches (ActivityCache, TermsCache): the shared
    # store makes the activity debounce exact and terms-accept visible across all
    # nodes instead of per-node. Reuses the same REDIS_URL on its own connection;
    # fails open to the DB read-through if the store is unreachable (see Engram.Cache).
    config :engram, Engram.Cache, backend: :redis, url: redis_url
  end

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
    instance: System.get_env("HOSTNAME", System.get_env("ECS_TASK_ID", "unknown"))
end
