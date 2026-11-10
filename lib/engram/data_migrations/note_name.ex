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

  A row that never decrypts (or whose owner has no key) is parked: stamped
  unreadable for its current ciphertext, logged and counted, so it cannot
  hold the ledger open. Rows whose owner's key does not load for a reason
  that can pass (`Crypto.key_outcome/1` `:later`: a rotation, KMS, a wrap the
  master key does not open) are deferred and keep the ledger OPEN: done must
  mean named, and S3's read switch waits on it. The chain stops after a walk
  that fixed nothing, and the next full walk waits a day
  (`Engram.Backfill.WalkMemo`, shared with `NameTerms`), so a stuck user costs
  one walk a day, never one an hour; the 7-day stuck alert asks a human. A walk starts, and the ledger closes, only while every cluster node
  writes names (`fleet_ready?/1`).

  Not re-verified: once done, a previous-release write (a rollback) leaves a
  stamp mismatch that S3's readers distrust (they decrypt the path instead).
  Bump `version/0` to walk again.

  Kill switch: `enabled?/0` is the `note_name_backfill` service override
  (default on); off, the runner starts nothing and the chain stops at its next
  hop. Pace: `note_name_backfill_max_rows` (rows per hop, default 500).
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.WalkMemo
  alias Engram.Cluster.Readiness
  alias Engram.DataMigrations
  alias Engram.Logger.Metadata
  alias Engram.Notes.Name
  alias Engram.Workers.BackfillNoteNames

  require Logger

  @max_rows 500
  @last_walk "note_name:last_walk"

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

      # The last walk handled nothing it found (every stale row deferred):
      # no new walk for a day, the ledger stays open (`WalkMemo`).
      WalkMemo.fruitless?(@last_walk) ->
        {:more, chains: 0, waiting: 1}

      true ->
        {:ok, _} = Oban.insert(BackfillNoteNames.new(%{}))
        {:more, chains: 1}
    end
  end

  @doc """
  True while every cluster node writes names (`Name.writer_level/0`, through
  `Engram.Cluster.Readiness.peers_report/4`, the gate `FileTimes` and
  `CompressionGate` use): a walk starts, and the ledger closes, only then, so
  no older node in a rolling deploy can add unnamed rows behind the closing
  walk. `fleet` overrides the gate's collaborators (tests). No `:global.sync/0`
  (as `FileTimes`): a sync stalls on a partition.
  """
  @spec fleet_ready?(keyword()) :: boolean()
  def fleet_ready?(fleet \\ []) do
    opts = Keyword.merge([sync: fn -> :ok end], fleet)

    case Readiness.peers_report(Name, :writer_level, 1, opts) do
      :ok ->
        true

      {reason, node} ->
        Logger.info(
          "note name backfill waiting for the fleet",
          Metadata.with_category(:info, :oban, reason: reason, peer: inspect(node))
        )

        false
    end
  end

  @doc "Records a complete chain walk that fixed `fixed` rows (`WalkMemo`)."
  @spec walked(non_neg_integer()) :: :ok
  def walked(fixed), do: WalkMemo.walked(@last_walk, fixed)

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
