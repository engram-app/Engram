defmodule Engram.Folders.MarkerStop do
  @moduledoc """
  Whether folder creates stop inserting `kind = 'folder'` marker rows and
  make the folder explicit on its `folders` row alone (S6 step 4, phase 2,
  Engram#2523). Listings read `folders.explicit` since phase 1
  (`Engram.Folders.Rows.explicit_reads?/0`), so a marker is redundant once
  every node that can serve, and every release a rollback can land on,
  reads the flag.

  On only while all of these hold, read per op, so an upgrade needs no
  operator step:

    * no runtime switch: release J dropped the `folder_marker_stop` service
      override (a row left under it is ignored), because a marker J writes
      lives forever (its delete ledger is retired) and keeps release I's
      hash-matching reconcile alive for the vault across a rollback. The
      `:folder_marker_stop` app env stays as the suites' lever (tests only,
      default on) for the marker path below;
    * listings read the flag (`Rows.explicit_reads?/0`: the `folder_table`
      ledger is done), so a self-host that skipped releases keeps writing
      markers until its ledger closes;
    * the rollback floor is at or above the release with the phase 1 reads
      (`@reads_release`): a release that reads markers would not list a
      folder created without one. Release D's tag, so this is inert until
      the floor-raise PR raises `priv/release_floor` to it (the
      `Engram.Folders.WriteStop` pattern).
      `:marker_stop_floors, :assume` (tests only) skips this one check.
  """

  alias Engram.Folders.Rows
  alias Engram.Release.Floor

  # The release with the phase 1 explicit-folder reads (release D).
  @reads_release "release-v0.90.0"

  @doc "The first release whose listings read `folders.explicit`: the rollback floor must reach it."
  @spec reads_release() :: String.t()
  def reads_release, do: @reads_release

  @doc "Whether folder creates skip the marker row (see the moduledoc)."
  @spec on?() :: boolean()
  def on? do
    Engram.ServiceConfig.env(:folder_marker_stop, true) != false and floors?() and
      Rows.explicit_reads?()
  end

  @doc "Whether the rollback floor covers the phase 1 reads release."
  @spec floors?(:assume | :enforce) :: boolean()
  def floors?(mode \\ Engram.ServiceConfig.env(:marker_stop_floors, :enforce)),
    do: mode == :assume or Floor.at_least?(@reads_release)
end
