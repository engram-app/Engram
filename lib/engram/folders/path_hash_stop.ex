defmodule Engram.Folders.PathHashStop do
  @moduledoc """
  S6 step 3 phase 2 (Engram#2523): whether folder writes in a vault stop
  writing `folders.full_path_hmac`, so a rename writes one row and reads only
  it. Per vault, on only when BOTH hold:

    * the rollback floor reaches release D, the first release that finds
      folders by chain, not by the hash (`docs/context/rollback-floor.md`);
    * S6 step 4 has removed the vault's folder markers
      (`Engram.DataMigrations.FolderMarkerDelete.done?/2`: the ledger done and
      no live marker in the vault right now, an O(1) probe, so never stale
      after a rollback). With markers present a folder op still reads them
      by their path hash, which only stays right while the hash is written.

  Anywhere either is false the vault gets release D's behaviour: every writer
  keeps the hash. `@reads_release` is a placeholder no real floor reaches, so
  the stop ships INERT; the floor-raise PR sets D's tag.

  The tests run with both assumed (`config :engram, :path_hash_stop_floors,
  :assume` and `:path_hash_stop_markers_gone, true`) and pin the inert
  default (`PathHashStopTest`, `PathHashStopInertTest`).

  Maintenance passes (`FolderTable`, the DEK rotation) always write the hash,
  as D: harmless where the stop is on (nothing reads it there), and right
  for a vault that falls back.
  """

  alias Engram.Release.Floor

  # ponytail: placeholder until the floor-raise PR names release D's tag.
  @reads_release "release-v999.0.0"
  # S6 step 4's ledger ships in a separate stack (Engram#2652, on #2649).
  # Until both are on main the module may be absent, which reads as "markers
  # present": D's behaviour. Called through a variable, so this compiles
  # without it.
  @marker_delete Engram.DataMigrations.FolderMarkerDelete

  @doc "The release with S6 step 3's chain readers: the rollback floor must reach it."
  @spec reads_release() :: String.t()
  def reads_release, do: @reads_release

  @doc """
  Whether writes in `vault_id` stop writing `full_path_hmac` (see the
  moduledoc). Runs inside the caller's tenant transaction (`user_id` owns
  the vault). The floor is checked first: while it is below D, no probe.
  """
  @spec on?(Ecto.UUID.t(), Ecto.UUID.t(), :assume | :enforce) :: boolean()
  def on?(
        user_id,
        vault_id,
        mode \\ Application.get_env(:engram, :path_hash_stop_floors, :enforce)
      ),
      do: floors?(mode) and markers_gone?(user_id, vault_id)

  @doc "Whether writes in `vault_id` still write the hash: `not on?/2`."
  @spec write?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def write?(user_id, vault_id), do: not on?(user_id, vault_id)

  @doc "Whether the rollback floor reaches release D."
  @spec floors?(:assume | :enforce) :: boolean()
  def floors?(mode \\ Application.get_env(:engram, :path_hash_stop_floors, :enforce)),
    do: mode == :assume or Floor.at_least?(@reads_release)

  @doc "Whether `vault_id` has no folder marker left (S6 step 4)."
  @spec markers_gone?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def markers_gone?(user_id, vault_id) do
    # Tests pin a state (`true`/`false`) or a stand-in ledger module with
    # `:path_hash_stop_markers_gone`; unset (prod) asks the real ledger.
    case Application.get_env(:engram, :path_hash_stop_markers_gone, @marker_delete) do
      gone? when is_boolean(gone?) -> gone?
      mod -> marker_delete_done?(mod, user_id, vault_id)
    end
  end

  @doc false
  @spec marker_delete_done?(module(), Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def marker_delete_done?(mod, user_id, vault_id) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :done?, 2) and
      mod.done?(user_id, vault_id) == true
  end
end
