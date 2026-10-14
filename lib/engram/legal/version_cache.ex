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

  # Stored with the date it was computed for: the floor moves when a material
  # version's effective_date arrives, which no publish or reseed announces. One
  # entry per document, replaced when the date changes. The date is an ISO
  # string, never a %Date{} (a struct makes Cache's match-spec store fail).
  @spec required_floor(String.t(), Date.t()) :: String.t() | nil
  def required_floor(document, today \\ Date.utc_today()) do
    day = Date.to_iso8601(today)
    load = fn -> {day, Legal.required_floor(document, today)} end

    case Cache.fetch(:legal_version, {:floor, document}, load) do
      {^day, floor} ->
        floor

      _other_day ->
        {^day, floor} = entry = load.()
        :ok = Cache.put(:legal_version, {:floor, document}, entry)
        floor
    end
  end

  @spec versions(String.t()) :: [Engram.Legal.TermsVersion.t()]
  def versions(document),
    do: Cache.fetch(:legal_version, {:versions, document}, fn -> Legal.versions(document) end)

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
