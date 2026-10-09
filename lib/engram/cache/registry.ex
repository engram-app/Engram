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
    # entries are added by later tasks
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
