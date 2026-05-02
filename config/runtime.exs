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
  # Storage backend — select adapter from STORAGE_BACKEND env var (s3 or database)
  case System.get_env("STORAGE_BACKEND", "database") do
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

    _ ->
      config :engram, :storage, Engram.Storage.Database
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
auth_provider = case System.get_env("AUTH_PROVIDER", "local") do
  "local" -> :local
  "clerk" -> :clerk
  other -> raise "Invalid AUTH_PROVIDER=#{other}. Valid values: local, clerk"
end
config :engram, :auth_provider, auth_provider

# Rate limit override for CI E2E tests (only effective when CI=true).
# Production deploys never set CI=true, so this is unreachable in prod.
if override = System.get_env("RATE_LIMIT_AUTH_OVERRIDE") do
  config :engram, :rate_limit_auth_override, String.to_integer(override)
end

# Clerk auth (only required when AUTH_PROVIDER=clerk)
# Note: use local variable, not Application.get_env — runtime.exs config
# is accumulated and not yet applied, so get_env reads stale config.
if auth_provider == :clerk do
  clerk_jwks_url = System.get_env("CLERK_JWKS_URL") ||
    raise "CLERK_JWKS_URL is required when AUTH_PROVIDER=clerk"
  config :engram, :clerk_jwks_url, String.trim(clerk_jwks_url)

  clerk_issuer = System.get_env("CLERK_ISSUER") ||
    raise "CLERK_ISSUER is required when AUTH_PROVIDER=clerk"
  config :engram, :clerk_issuer, String.trim(clerk_issuer)

  clerk_pub_key =
    case System.get_env("CLERK_PUBLISHABLE_KEY") do
      nil -> raise "CLERK_PUBLISHABLE_KEY is required when AUTH_PROVIDER=clerk"
      "" -> raise "CLERK_PUBLISHABLE_KEY is set but empty when AUTH_PROVIDER=clerk"
      key -> key
    end
  config :engram, :clerk_publishable_key, clerk_pub_key
end

# Stripe billing
if stripe_key = System.get_env("STRIPE_SECRET_KEY") do
  config :stripity_stripe, api_key: stripe_key
end

if stripe_webhook_secret = System.get_env("STRIPE_WEBHOOK_SECRET") do
  config :engram, :stripe_webhook_secret, stripe_webhook_secret
end

if config_env() != :test do
  config :engram, :stripe_starter_price_id, System.get_env("STRIPE_STARTER_PRICE_ID")
  config :engram, :stripe_pro_price_id, System.get_env("STRIPE_PRO_PRICE_ID")
end

# Key provider — skip in :test so test.exs stable key is not overwritten by a nil env read.
# Dev and prod (including Docker CI containers) read from KEY_PROVIDER / ENCRYPTION_MASTER_KEY.
if config_env() != :test do
  key_provider_module =
    case System.get_env("KEY_PROVIDER", "local") do
      "local" -> Engram.Crypto.KeyProvider.Local
      other -> raise "Unknown KEY_PROVIDER=#{other}; supported: local"
    end

  config :engram,
    key_provider: key_provider_module,
    encryption_master_key: System.get_env("ENCRYPTION_MASTER_KEY"),
    encryption_master_key_previous: System.get_env("ENCRYPTION_MASTER_KEY_PREVIOUS"),
    dek_cache_ttl_ms: String.to_integer(System.get_env("DEK_CACHE_TTL_MS", "3600000"))
end

# Endpoint URL — used by EngramWeb.Endpoint.url() for device flow verification links,
# email URLs, etc. Works in dev and prod. Defaults to localhost in dev.
# PHX_HOST may be a comma-separated list; the FIRST entry is canonical.
phx_hosts = Engram.HostOrigins.parse(System.get_env("PHX_HOST"))

if phx_hosts do
  scheme = System.get_env("PHX_SCHEME") || if(config_env() == :prod, do: "https", else: "http")
  url_port = String.to_integer(System.get_env("PHX_PORT") || if(config_env() == :prod, do: "443", else: "80"))

  config :engram, EngramWeb.Endpoint,
    url: [host: phx_hosts.canonical_host, port: url_port, scheme: scheme]
end

if config_env() == :prod do
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
    socket_options: maybe_ipv6

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
