defmodule Engram.Folders.WriteStop do
  @moduledoc """
  Whether a folder rename or move writes ONE folder row instead of
  cascading into every note under it (O(1) folder rename plan, S5,
  Engram#2523). On, `Engram.Folders.rename/5` moves the folder row with
  `notes_cascaded = false` at one seq, and readers derive each note's path
  from its folder chain plus its name (`Engram.Notes.Location`). Off, or
  for an op the write stop cannot serve (see `Engram.Notes.rename_folder_uncascaded/4`),
  the cascade runs as before.

  On only while all of these hold, read per op, so an upgrade needs no
  operator step and a self-host that skipped releases cascades until its
  ledgers catch up:

    * the `folder_write_stop` service override is not false (a kill switch,
      default on, no deploy);
    * the folder-op wire is on (`Engram.Folders.Wire.enabled?/0`): clients
      learn a folder move from `folder_changed` and the manifest's
      `folders`, since no note row carries it;
    * names are read (`Engram.Notes.Location.on?/0`: the `note_name` ledger
      is done and `name_reads` is not off), so every reader derives.

    * the rollback floor is at or above the release with the moved-folder
      feed (`@reads_release`), so no rollback lands on code that misreads
      or mis-serves these rows. Compile-time; `:write_stop_floors, :assume`
      (test config only) skips this one check;
    * every connected node serves them (`Engram.Notes.Location.s5_reads/0`
      at least 2, `Engram.Cluster.Readiness`): it reads them, and it
      serves them to plugins older than the S4 one through the moved-folder
      feed (`Engram.Notes.list_moved_changes/4`) and the manifest's moved
      seq, so no plugin floor is needed (god, 2026-11-17).

  Turning `folder_write_stop` off needs no re-cascade: every release at or
  above the floor serves the folders already moved this way.

  Once moves exist, names stay read in those vaults whatever `name_reads`
  or the `note_name` ledger say (`Engram.Notes.Location`'s latch): a
  path-only read there would show moved notes at their old paths and let a
  create at the shown path duplicate one. So `name_reads` off, a reopened
  ledger or a `NoteName` version bump only stops NEW uncascaded moves (this
  `on?/0` reads `Location.on?/0`) and the S3 wire extras; a bumped ledger
  refills names while every moved vault keeps reading them, each row
  trusted only while its name stamp is current.

  ## Preconditions to lower `s4_plugin`

  `@s4_plugin` is a sentinel, so every plugin gets the moved-folder feed and
  `folder_ops` is safe to enable. Lowering it to a real version turns the
  feed off for those clients. Before that, set `@verified_folder_move_plugin`
  (`Engram.Folders.WriteStopFloorTest` keeps `@s4_plugin` at or above it) to
  a release that meets all of:

    * it applies folder moves for folders it did not create (the plugin fix
      for `followFolderMoveOnDisk` resolving `from`);
    * it has at least 7 days of adoption;
    * a staging table with `folder_ops` on passes with a fresh and an
      already-synced plugin at that version.
  """

  alias Engram.Cluster.Readiness
  alias Engram.Crypto.HMAC
  alias Engram.Folders.Wire
  alias Engram.Logger.Metadata
  alias Engram.Notes.Location
  alias Engram.Release.Floor

  require Logger

  @cascade_reasons [
    :stop_off,
    :no_op,
    :no_old_row,
    :new_folder_exists,
    :merge_raced,
    :empty,
    :not_derivable,
    :drift,
    :unkeyed,
    :raced
  ]

  # The release with the moved-folder feed and the shown-path announces
  # (release A, Engram#2609). The rollback floor reaching it (release B,
  # `priv/release_floor`, which also requires the tag to contain 2609's merge
  # commit, `priv/release_floor_contains`) is what switches the writer on:
  # no rollback can then land on a release without them.
  #
  # S4 plugin: SENTINEL that no released plugin reaches, so every client gets
  # the moved-folder feed. Engram-obsidian#689 was cut as 1.40.0, but 1.40.0
  # does not learn uncascaded moves from `folder_changed` + the manifest (e2e
  # test_108: no notes or attachments under such a folder). Set this to the
  # first plugin release an e2e proves handles them, and flip
  # `Engram.Folders.WriteStopFloorTest` to match.
  @reads_release "release-v0.88.0"
  @s4_plugin "999.0.0"
  # See "Preconditions to lower `s4_plugin`" in the moduledoc. nil: none yet.
  @verified_folder_move_plugin nil
  # `Location.s5_reads/0` level a node needs: the readers plus the moved-folder feed.
  @fleet_level 2

  @doc """
  One structured line for a folder op that fell back to the cascade, naming
  the branch that decided it (the reasons are the `@cascade_reasons` atoms;
  `new_folder_exists` is the pre-check, `merge_raced` a folder that appeared
  at the target during the locked move, `raced` a note written after the
  scan). Hashed user and vault ids only: no path, no name, no count of
  notes. Emitted once per op by `Folders.rename/5` after the claim retries
  settle, never per attempt or per note.
  """
  @spec log_cascade(map(), map(), atom()) :: :ok
  def log_cascade(user, vault, reason) when reason in @cascade_reasons do
    Logger.info(
      "folder_op cascade reason=#{reason}",
      Metadata.with_category(:info, :sync,
        user_id: HMAC.hash_user_id(to_string(user.id)),
        vault_id: HMAC.hash_id(to_string(vault.id))
      )
    )

    :ok
  end

  @doc "The first release with the S5 readers: the rollback floor must reach it."
  @spec reads_release() :: String.t()
  def reads_release, do: @reads_release

  @doc "The first plugin that skips the moved-folder feed (`Engram.Sync.moved_feed?/1`); a sentinel today."
  @spec s4_plugin() :: String.t()
  def s4_plugin, do: @s4_plugin

  @doc "The plugin release proven to apply uncascaded folder moves, or nil (see the moduledoc)."
  @spec verified_folder_move_plugin() :: String.t() | nil
  def verified_folder_move_plugin, do: @verified_folder_move_plugin

  @doc "Whether folder renames and moves write one folder row (see the moduledoc)."
  @spec on?() :: boolean()
  def on? do
    Engram.ServiceConfig.get(:folder_write_stop, true) != false and floors?() and
      Wire.enabled?() and Location.on?() and fleet?()
  end

  @doc "Whether the rollback floor covers the moved-folder feed release."
  @spec floors?(:assume | :enforce) :: boolean()
  def floors?(mode \\ Application.get_env(:engram, :write_stop_floors, :enforce)),
    do: mode == :assume or Floor.at_least?(@reads_release)

  defp fleet?,
    do: Readiness.peers_report(Location, :s5_reads, @fleet_level, sync: fn -> :ok end) == :ok
end
