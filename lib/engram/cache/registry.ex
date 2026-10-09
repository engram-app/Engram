defmodule Engram.Cache.Registry do
  @moduledoc """
  Every node-local cache in the app, declared once. `Engram.Cache.Server`
  creates one ETS table per entry. Options:

    * `ttl` - ms, or `:infinity`. A backstop: freshness comes from eviction.
    * `cache_nil` - store a `nil` loader result (negative caching).
    * `evict_match` - `:key` evicts the exact key; `:first_elem` evicts every
      `{id, _}` key for `id` (a per-user cache keyed by `{user_id, x}`).
    * `pg_channel` - Postgres NOTIFY channel whose payload (a string) is the
      key to evict. Fired by AFTER-write triggers, so raw SQL is covered too.
  """

  @base [
    # Hits AND misses of user_limit_overrides, keyed {user_id, limit_key};
    # evicted per user (Postgres NOTIFY payload is the user id).
    %{
      name: :billing_override,
      ttl: 60_000,
      cache_nil: true,
      evict_match: :first_elem,
      pg_channel: "user_limit_overrides_changed"
    },
    # Fully resolved capability map per user. Freshness is explicit eviction;
    # the 24h TTL is only a backstop.
    %{
      name: :billing_entitlement,
      ttl: 86_400_000,
      cache_nil: false,
      evict_match: :key,
      pg_channel: "user_limit_overrides_changed"
    },
    # Per-vault avgdl (BM25 length normalizer); a soft value, TTL-only.
    %{name: :avgdl, ttl: 600_000, cache_nil: false, evict_match: :key, pg_channel: nil},
    # CIMD client signing keys by jwks_uri; public keys, TTL-only.
    %{name: :jwks, ttl: 3_600_000, cache_nil: false, evict_match: :key, pg_channel: nil},
    # RequireOnboarding PASS verdict per user (value is the expiry deadline).
    %{
      name: :onboarding_gate,
      ttl: 60_000,
      cache_nil: false,
      evict_match: :key,
      pg_channel: nil
    },
    # Latest accepted terms version per {user_id, document}; monotonic.
    %{name: :terms, ttl: :infinity, cache_nil: false, evict_match: :key, pg_channel: nil},
    # Last usage_meters.last_active_at stamp per user (debounce).
    %{name: :activity, ttl: :infinity, cache_nil: false, evict_match: :key, pg_channel: nil},
    # Plan limits maps by plan id; plan rows are static at runtime.
    %{name: :plan, ttl: :infinity, cache_nil: true, evict_match: :key, pg_channel: nil},
    # Per-request auth and tenancy lookups. Freshness comes from the
    # AFTER-write NOTIFY triggers (migration 20261009120000), which fire for
    # every writer including raw SQL; the TTL is only a backstop.
    # users.id => %User{} (subscription NOT loaded). Carries deleted_at,
    # suspended_at, dek_rotation_locked_at, so every users UPDATE evicts.
    %{name: :user, ttl: 60_000, cache_nil: false, evict_match: :key, pg_channel: "users_changed"},
    # api_keys.key_hash (the hex text the trigger sends) => %ApiKey{} without
    # :user. Revocation deletes the row; the 30s TTL bounds a lost NOTIFY.
    %{
      name: :api_key,
      ttl: 30_000,
      cache_nil: false,
      evict_match: :key,
      pg_channel: "api_keys_changed"
    },
    # api_keys.id => :all | [vault_id] (the key's vault restriction).
    %{
      name: :api_key_scope,
      ttl: 30_000,
      cache_nil: false,
      evict_match: :key,
      pg_channel: "api_key_vaults_changed"
    },
    # users.id => %Subscription{} | nil (nil cached: most users have none).
    %{
      name: :subscription,
      ttl: 60_000,
      cache_nil: true,
      evict_match: :key,
      pg_channel: "subscriptions_changed"
    },
    # users.id => active vaults, decrypted. The trigger ignores change_seq /
    # updated_at-only updates (every note write bumps them), so never read the
    # seq off these structs: use Vaults.current_seq/2.
    %{
      name: :vaults,
      ttl: 60_000,
      cache_nil: false,
      evict_match: :key,
      pg_channel: "vaults_changed"
    },
    # Legal floor / current version / hash per document; evicted on publish.
    %{
      name: :legal_version,
      ttl: :infinity,
      cache_nil: true,
      evict_match: :key,
      pg_channel: nil
    }
  ]

  if Mix.env() == :test do
    @test_caches [
      %{
        name: :test_cache,
        ttl: 50,
        cache_nil: false,
        evict_match: :key,
        pg_channel: "test_cache_changed"
      },
      %{name: :test_cache_nil, ttl: 50, cache_nil: true, evict_match: :key, pg_channel: nil},
      %{
        name: :test_cache_forever,
        ttl: :infinity,
        cache_nil: false,
        evict_match: :key,
        pg_channel: nil
      },
      %{
        name: :test_cache_pairs,
        ttl: 60_000,
        cache_nil: false,
        evict_match: :first_elem,
        pg_channel: nil
      }
    ]
  else
    @test_caches []
  end

  @tables Map.new(@base ++ @test_caches, &{&1.name, :"engram_cache_#{&1.name}"})

  @spec caches() :: [map()]
  def caches, do: @base ++ @test_caches

  @spec fetch!(atom()) :: map()
  def fetch!(name),
    do:
      Enum.find(caches(), &(&1.name == name)) ||
        raise(ArgumentError, "unknown cache #{inspect(name)}")

  @spec table(atom()) :: atom()
  def table(name) do
    # Table atoms are built at compile time from the declared caches, so an
    # unknown name raises ArgumentError (which Engram.Cache treats as a miss)
    # instead of minting an atom at runtime.
    case Map.fetch(@tables, name) do
      {:ok, table} -> table
      :error -> raise ArgumentError, "unknown cache #{inspect(name)}"
    end
  end
end
