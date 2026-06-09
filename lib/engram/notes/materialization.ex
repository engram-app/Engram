defmodule Engram.Notes.Materialization do
  @moduledoc """
  Discovers virtual folders implied by existing notes and inserts real
  `folder_marker` rows (kind="folder") so every folder path becomes a
  stable, addressable DB row. Idempotent and re-runnable.

  Used by the folder-identity migration that backs the Headless Tree
  rollout: once a folder is a real row, it has a stable id consumers
  can key off of (drag/drop targets, tree expansion state, etc.).

  ## Implementation notes

  - Per-vault atomic transaction. If the run fails partway through, no
    partial state is committed.
  - Reuses `Notes.create_folder_marker/3` for inserts, which means new
    markers get HMAC + DEK + AAD binding via the same code path everything
    else uses. No new crypto surface.
  - Concurrent inserters (race) are tolerated: a `{:error, _}` from
    `create_folder_marker/3` for an already-existing folder is silently
    absorbed (the marker exists, which is the intended end state).
  - `list_all_note_folders/2` enumerates encrypted rows + decrypts each.
    Fine for backfill; not appropriate for hot paths.
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
            {:ok, _} -> acc + 1
            # Race: marker created by a concurrent process between our read
            # and write. End-state is the marker exists, which is correct.
            {:error, _} -> acc
          end
        end)

      %{inserted: inserted, existing: MapSet.size(existing_paths)}
    end)
  end

  defp collect_implied_folder_paths(user, vault) do
    user
    |> Notes.list_all_note_folders(vault)
    |> Enum.flat_map(&ancestors/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
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
