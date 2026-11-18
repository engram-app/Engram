defmodule Engram.Attachments.WriteStop do
  @moduledoc """
  Whether a folder rename that the S5 write stop serves without a cascade
  (`Engram.Folders.WriteStop`) also leaves the attachments under the folder
  where they are: no attachment row written, no tombstone, no per-file
  broadcast (O(1) folder rename plan, S6 step 6 phase 2, Engram#2523).
  Readers find and show each such attachment by its folder row and name
  (`Engram.Attachments.Location`, release D). Off, or for an op this cannot
  serve, `Engram.Attachments.move_folder_pairs/3` cascades as before.

  On only while all of these hold, read per op before the transaction, so
  an upgrade needs no operator step and a self-host that skipped releases
  cascades until its ledgers catch up:

    * the `attachment_write_stop` service override is not false (a kill
      switch, default on, no deploy);
    * the S5 note write stop is on (`Engram.Folders.WriteStop.on?/0`: names
      read, the folder-op wire, its floor and fleet);
    * the `attachment_name_key` ledger is done, so every keyable attachment
      can be found by name;
    * the rollback floor is at or above the release with the attachment
      readers (`@reads_release`). Compile-time; `:write_stop_floors,
      :assume` (test config only) skips this check;
    * every connected node reads them (`Location.s6_reads/0` at least
      `@fleet_level`, `Engram.Cluster.Readiness`), and so serves them to
      plugins older than S4 through the moved-folder feed's attachment leg.

  The op itself also falls back to the cascade when any attachment under
  the folder has no `name_key` (the trigger keys it only while its name and
  folder reference are current): such a row is read at
  its stored path, which the move would orphan.

  Turning it off needs no re-cascade: every release at or above the floor
  reads attachments already left this way, and writers settle them
  (`Engram.Attachments.settle/3`) when they next touch them.
  """

  alias Engram.Attachments.Location
  alias Engram.Cluster.Readiness
  alias Engram.DataMigrations
  alias Engram.DataMigrations.AttachmentNameKey
  alias Engram.Folders.WriteStop, as: NoteWriteStop
  alias Engram.Release.Floor

  # The release with the attachment readers (release D, PR 2640). A SENTINEL
  # no floor can reach, so this writer is inert whatever tag release-please
  # cuts: the floor PR (Todd's approval) sets this and `priv/release_floor`
  # to D's real tag together, with a check that the tag contains the readers.
  @reads_release "release-v999.0.0"
  # `Location.s6_reads/0` a node needs: the attachment readers and feed leg.
  @fleet_level 1

  @doc "The first release with the attachment readers: the rollback floor must reach it."
  @spec reads_release() :: String.t()
  def reads_release, do: @reads_release

  @doc "Whether a folder rename the S5 write stop serves leaves attachments in place."
  @spec on?() :: boolean()
  def on? do
    Engram.ServiceConfig.get(:attachment_write_stop, true) != false and floors?() and
      NoteWriteStop.on?() and ledger_done?() and fleet?()
  end

  @doc "Whether the rollback floor covers the attachment readers release."
  @spec floors?(:assume | :enforce) :: boolean()
  def floors?(mode \\ Application.get_env(:engram, :write_stop_floors, :enforce)),
    do: mode == :assume or Floor.at_least?(@reads_release)

  # `:attachment_name_key_ledger` is unset outside tests (the ledger row is
  # read); a test sets `:done` per process, so it never flips the writer for
  # the rest of the suite (`done?/2` caches a `true` node-wide).
  defp ledger_done? do
    Engram.ServiceConfig.get(:attachment_name_key_ledger, :read) == :done or
      DataMigrations.done?(AttachmentNameKey.name(), AttachmentNameKey.version())
  end

  defp fleet?,
    do: Readiness.peers_report(Location, :s6_reads, @fleet_level, sync: fn -> :ok end) == :ok
end
