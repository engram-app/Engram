defmodule Engram.LegalFixtures do
  @moduledoc "Insert terms_versions rows in tests."
  alias Engram.Legal.TermsVersion
  alias Engram.Legal.VersionCache
  alias Engram.Repo

  @doc """
  Reset the version cache for a test and wait for any in-flight broadcast to
  drain. `VersionCache.invalidate_all/0` clears `:persistent_term` synchronously
  AND fires an async PubSub broadcast; the local `Invalidator` GenServer
  receives that broadcast and clears again. Without the barrier, the loopback
  can land mid-test and erase cache rows the test just wrote, surfacing as
  intermittent failures of memoization assertions.
  """
  def reset_version_cache do
    VersionCache.invalidate_all()
    _ = :sys.get_state(VersionCache.Invalidator)
    :ok
  end

  @doc """
  Insert a version row. Defaults: terms_of_service, material, effective now.
  Pass `effective_date:` a `~D[]` in the future for the notice-window case.
  """
  def insert_version(attrs \\ %{}) do
    attrs = Map.new(attrs)

    defaults = %{
      document: "terms_of_service",
      version: "2026-05-19",
      content_hash: "hash-" <> (attrs[:version] || "2026-05-19"),
      material: true,
      effective_date: nil,
      changelog: "test"
    }

    %TermsVersion{}
    |> TermsVersion.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!(skip_tenant_check: true)
  end
end
