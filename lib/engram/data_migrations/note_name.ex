defmodule Engram.DataMigrations.NoteName do
  @moduledoc """
  O(1) folder rename plan, S2 migrate-data (Engram#2523): every note and
  attachment row (live, trashed or tombstone) carries a current name
  (`Engram.Notes.Name`: `name_stamp` matches its `path_nonce`), and every
  folder row a current `name_ci_hmac` (`name_stamp` matches its `name_nonce`).
  Rows written before S2, or by the previous release during a rolling deploy
  or after a rollback (an insert leaves the name NULL, a rename leaves it
  stale), are the work.

  The work runs in ONE paced chain, `Engram.Workers.BackfillNoteNames`, not in
  the hourly runner pass: at one bounded slice per hourly pass the prod
  backfill would take days, and the S3 read switch waits on this ledger. Each
  pass here only starts the chain when none is in flight. The chain marks the
  ledger done itself, after one complete walk of all three tables that fixed
  nothing and left nothing (the completion check of
  `docs/context/data-migrations-ledger.md`; no fleet-wide EXISTS).

  A row that never decrypts keeps the ledger open: the chain stops after a
  walk that found only such rows, and the next hourly pass starts one more
  walk (one cheap walk an hour, never a hot loop), until the 7-day stuck alert
  asks a human.

  Not re-verified: once done, a previous-release write (a rollback) leaves a
  stamp mismatch that S3's readers distrust (they decrypt the path instead).
  Bump `version/0` to walk again.

  Kill switch: `enabled?/0` is the `note_name_backfill` service override
  (default on); off, the runner starts nothing and the chain stops at its next
  hop. Pace: `note_name_backfill_max_rows` (rows per hop, default 500).
  """
  @behaviour Engram.DataMigration

  alias Engram.DataMigrations
  alias Engram.Logger.Metadata
  alias Engram.Workers.BackfillNoteNames

  require Logger

  @max_rows 500

  @impl true
  def name, do: "note_name"

  @impl true
  def version, do: 1

  @doc "Kill switch: the `note_name_backfill` service override (default on)."
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:note_name_backfill, true) == true

  @doc "True once every row carries a current name (S3 reads names only then)."
  @spec done?() :: boolean()
  def done?, do: DataMigrations.done?(name(), version())

  @impl true
  def run_pass do
    cond do
      # The chain closed the ledger after this runner's `done?` read.
      DataMigrations.completed_at(name(), version()) ->
        :done

      DataMigrations.jobs_in_flight?(BackfillNoteNames) ->
        {:more, chains: 1}

      true ->
        {:ok, _} = Oban.insert(BackfillNoteNames.new(%{}))
        {:more, chains: 1}
    end
  end

  @doc "Rows a chain hop fixes at most: the `note_name_backfill_max_rows` override."
  @spec max_rows() :: pos_integer()
  def max_rows do
    case Engram.ServiceConfig.get(:note_name_backfill_max_rows, @max_rows) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        Logger.warning(
          "note_name_backfill_max_rows is not a positive integer, using #{@max_rows}",
          Metadata.with_category(:warning, :data)
        )

        @max_rows
    end
  end
end
