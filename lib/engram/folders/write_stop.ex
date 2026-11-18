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
  """

  alias Engram.Cluster.Readiness
  alias Engram.Folders.Wire
  alias Engram.Notes.Location
  alias Engram.Release.Floor

  # The release with the moved-folder feed and the shown-path announces
  # (release A, Engram#2609). The rollback floor reaching it (release B,
  # `priv/release_floor`, which also requires the tag to contain 2609's merge
  # commit, `priv/release_floor_contains`) is what switches the writer on:
  # no rollback can then land on a release without them. S4 plugin:
  # Engram-obsidian#689, cut as 1.40.0 by its release PR 706.
  @reads_release "release-v0.88.0"
  @s4_plugin "1.40.0"
  # `Location.s5_reads/0` level a node needs: the readers plus the moved-folder feed.
  @fleet_level 2

  @doc "The first release with the S5 readers: the rollback floor must reach it."
  @spec reads_release() :: String.t()
  def reads_release, do: @reads_release

  @doc "The first plugin that learns folder moves from `folder_changed` (`Engram.Sync.moved_feed?/1`)."
  @spec s4_plugin() :: String.t()
  def s4_plugin, do: @s4_plugin

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
