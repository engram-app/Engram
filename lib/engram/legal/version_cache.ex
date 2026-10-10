defmodule Engram.Legal.VersionCache do
  @moduledoc """
  Caches the computed gate inputs (`required_floor`, `current_version`, and
  per-version `hash_for`) in `Engram.Cache` (`:legal_version`, no TTL),
  mirroring `Engram.Billing.PlanCache`. Terms versions are seeded at boot and
  change only on a publish, so per-request reads should never touch the DB.
  Call `invalidate_all/0` after seeding or a publish so the next read reloads.
  """

  alias Engram.Cache
  alias Engram.Legal

  @spec required_floor(String.t()) :: String.t() | nil
  def required_floor(document),
    do: Cache.fetch(:legal_version, {:floor, document}, fn -> Legal.required_floor(document) end)

  @spec current_version(String.t()) :: String.t() | nil
  def current_version(document),
    do:
      Cache.fetch(:legal_version, {:current, document}, fn -> Legal.current_version(document) end)

  @spec hash_for(String.t(), String.t()) :: String.t() | nil
  def hash_for(document, version),
    do:
      Cache.fetch(:legal_version, {:hash, document, version}, fn ->
        Legal.hash_for(document, version)
      end)

  @doc """
  Drop every cached entry on this node AND tell peers to do the same. Call after
  a terms/privacy (re)seed or publish so every clustered node reloads the new
  version rows from the shared DB instead of serving a stale floor/hash. Also
  drops every `Engram.Onboarding.GateCache` verdict: a raised floor can flip
  any passed user back to failing.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ok = Cache.evict_all(:legal_version)
    Engram.Onboarding.GateCache.evict_all()
  end
end
