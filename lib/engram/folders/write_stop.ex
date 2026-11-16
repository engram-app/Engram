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

    * the floors cover what reads these rows: the rollback floor is at or
      above the release with the S5 readers (`@reads_release`), so no
      rollback lands on code that misreads them, and the plugin floor is at
      or above the S4 plugin (`@s4_plugin`), so no plugin that reads stored
      paths still syncs. Both are compile-time; `:write_stop_floors,
      :assume` (test config only) skips this one check;
    * every connected node runs the S5 readers
      (`Engram.Notes.Location.s5_reads/0`, `Engram.Cluster.Readiness`): no
      older node in a rolling deploy reads these rows.

  Once moves exist, keep names read: `name_reads` off (or a reopened
  `note_name` ledger) sends moved notes back to their stored, old paths in
  every reader. That switch is for before the first move, not after.
  """

  alias Engram.Cluster.Readiness
  alias Engram.Folders.Wire
  alias Engram.Notes.Location
  alias Engram.PluginVersion
  alias Engram.Release.Floor

  # Set to the real tags when the readers release and the S4 plugin ship.
  @reads_release "release-v0.87.0"
  @s4_plugin "1.40.0"

  @doc "Whether folder renames and moves write one folder row (see the moduledoc)."
  @spec on?() :: boolean()
  def on? do
    Engram.ServiceConfig.get(:folder_write_stop, true) != false and floors?() and
      Wire.enabled?() and Location.on?() and fleet?()
  end

  @doc "Whether the rollback and plugin floors cover the S5 readers and the S4 plugin."
  @spec floors?() :: boolean()
  def floors? do
    Application.get_env(:engram, :write_stop_floors, :enforce) == :assume or
      (Floor.at_least?(@reads_release) and
         Version.compare(Version.parse!(PluginVersion.minimum()), Version.parse!(@s4_plugin)) !=
           :lt)
  end

  defp fleet?, do: Readiness.peers_report(Location, :s5_reads, 1, sync: fn -> :ok end) == :ok
end
