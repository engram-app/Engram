defmodule Engram.Notes.Materialization do
  @moduledoc """
  Discovers virtual folders implied by existing notes and inserts real
  `folder_marker` rows (kind="folder") so every folder path becomes a
  stable, addressable DB row. Idempotent and re-runnable.

  Used by the folder-identity migration that backs the Headless Tree
  rollout: once a folder is a real row, it has a stable id consumers
  can key off of (drag/drop targets, tree expansion state, etc.).

  ## Semantics

  Best-effort idempotent backfill, wrapped in a per-vault transaction:

  - **Real failures roll back.** If `Notes.create_folder_marker/3`
    returns `{:error, reason}` mid-loop, the transaction is rolled back
    via `Repo.rollback({:create_folder_marker_failed, folder_path, reason})`
    — no partial state is committed. Re-running picks up where it left
    off because the operation is idempotent on the inputs that already
    succeeded on the next attempt.
  - **Race tolerance is implicit.** `create_folder_marker/3` returns
    `{:ok, existing_marker}` on a unique-constraint collision (it
    re-fetches the winner), so concurrent inserters do not surface as
    errors here. The end state — the marker exists — is correct.
  - **`inserted` is a heuristic counter.** It counts successful
    `create_folder_marker/3` calls in this run. Under a concurrent run
    against the same user (not a supported scenario), the counter may
    over-count by the size of the race window. Precision is not
    critical: this metric is for observability of bulk runs, not
    invariants.
  - `list_folders_implied_by_notes/2` enumerates encrypted rows +
    decrypts each. Fine for backfill; not appropriate for hot paths.

  Reuses `Notes.create_folder_marker/3` for inserts, which means new
  markers get HMAC + DEK + AAD binding via the same code path everything
  else uses. No new crypto surface.
  """

  alias Engram.Notes
  alias Engram.Repo

  @spec run(map(), map()) ::
          {:ok, %{inserted: non_neg_integer(), existing: non_neg_integer()}}
          | {:error, term()}
  def run(user, vault) do
    Repo.transaction(fn ->
      existing_markers = Notes.list_folder_markers(user, vault)
      existing_paths = MapSet.new(existing_markers, & &1.folder)

      paths_implied = collect_implied_folder_paths(user, vault)
      missing = Enum.reject(paths_implied, &MapSet.member?(existing_paths, &1))

      inserted =
        Enum.reduce(missing, 0, fn folder_path, acc ->
          case Notes.create_folder_marker(user, vault, folder_path) do
            {:ok, _} ->
              acc + 1

            {:error, reason} ->
              Repo.rollback({:create_folder_marker_failed, folder_path, reason})
          end
        end)

      %{inserted: inserted, existing: MapSet.size(existing_paths)}
    end)
  end

  @doc """
  Convenience entry-point for running materialization across every
  `(user, vault)` pair. Inline-safe for `bin/engram rpc` (Mix is
  unavailable in releases).
  """
  @spec run_all() :: :ok
  def run_all do
    Engram.Accounts.list_users()
    |> Enum.each(fn user ->
      Engram.Vaults.list_vaults(user)
      |> Enum.each(fn vault -> run(user, vault) end)
    end)
  end

  @doc """
  Returns the list of implied folder paths that do NOT yet have a
  matching `folder_marker` row for this `(user, vault)`. Empty list
  means materialization is up-to-date. Used by the CI gate test.
  """
  @spec orphans(map(), map()) :: [String.t()]
  def orphans(user, vault) do
    existing = MapSet.new(Notes.list_folder_markers(user, vault), & &1.folder)

    collect_implied_folder_paths(user, vault)
    |> Enum.reject(&MapSet.member?(existing, &1))
  end

  defp collect_implied_folder_paths(user, vault) do
    {:ok, folders} = Notes.list_folders_implied_by_notes(user, vault)

    folders
    |> Enum.flat_map(&ancestors/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
    # Deterministic order for test assertions + debug log readability.
    |> Enum.sort()
  end

  # "a/b/c" -> ["a", "a/b", "a/b/c"]
  defp ancestors(""), do: []

  defp ancestors(path) do
    segments = String.split(path, "/")

    Enum.map(1..length(segments), fn n ->
      segments |> Enum.take(n) |> Enum.join("/")
    end)
  end
end
