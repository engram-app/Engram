defmodule Engram.DataMigrations.NoteLinkQualified do
  @moduledoc """
  O(1) folder rename plan, S4.6 migrate-data (Engram#2523): every
  `note_links` row carries `qualified` (`Engram.Links.qualified?/1` of its
  decrypted target). Rows written before S4.6, or by the previous release
  during a rolling deploy, are NULL and are the work. S5's folder-rename
  gate reads the column (its qualified arm; a bare link on a colliding
  basename needs S5's separate collision arm) only once this ledger is done.

  The work runs in ONE paced chain, `Engram.Workers.BackfillNoteLinkQualified`
  (the `NoteName` pattern): each runner pass only starts the chain when none
  is in flight, and the chain marks the ledger done after one complete walk
  that fixed nothing and left nothing. A walk starts, and the ledger closes,
  only while every cluster node writes the column (`fleet_ready?/1`), so no
  older node can add NULL rows behind the closing walk.

  A target that never decrypts, or whose owner has no key, is classified
  `true`: the safe side, S5 then queues the rewrite job (which skips what it
  cannot read) instead of skipping a link that may need it. Rows of an owner
  whose key does not load for a reason that can pass (`Crypto.walk_dek/1`
  `:later`, a rotation in progress included) are left and keep the ledger
  open; the next full walk waits a day (`Engram.Backfill.WalkMemo`).

  Not re-verified: once done, only a rollback to 0.84.0 writes NULL rows.
  `Links.replace_links_basenames/4` rewrites them on the note's next
  extraction; bump `version/0` to walk the rest.

  Kill switch: `enabled?/0` is the `note_link_qualified_backfill` service
  override (default on); off, the runner starts nothing and the chain stops
  before its next window. Pace: `note_link_qualified_backfill_max_rows`
  (rows per hop, default 3,000) and `note_link_qualified_backfill_writes_per_s`
  (default 150); the pressure gate (`Engram.Backfill.Throttle.pressure/0`)
  holds a hop on a slow app pool or a long open transaction.
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.{Throttle, WalkMemo}
  alias Engram.Cluster.Readiness
  alias Engram.DataMigrations
  alias Engram.Links
  alias Engram.Logger.Metadata
  alias Engram.Workers.BackfillNoteLinkQualified

  require Logger

  # A link row is a short decrypt and a boolean, so a hop does six times
  # NoteName's 500: ~3,000 rows per ~65 s hop (20 s at the ceiling below
  # plus 45 s between hops), ~2,800 rows/min, ~12 h for prod's ~1.9M rows
  # (estimate, not measured).
  @max_rows 3_000
  @writes_per_s 150
  @last_walk "note_link_qualified:last_walk"

  @impl true
  def name, do: "note_link_qualified"

  @impl true
  def version, do: 1

  @doc "Kill switch: the `note_link_qualified_backfill` service override (default on)."
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:note_link_qualified_backfill, true) == true

  @doc "True once every row carries `qualified` (S5's gate reads it only then)."
  @spec done?() :: boolean()
  def done?, do: DataMigrations.done?(name(), version())

  @impl true
  def run_pass do
    cond do
      DataMigrations.completed_at(name(), version()) ->
        :done

      DataMigrations.jobs_in_flight?(BackfillNoteLinkQualified) ->
        {:more, chains: 1}

      WalkMemo.fruitless?(@last_walk) ->
        {:more, chains: 0, waiting: 1}

      true ->
        {:ok, _} = Oban.insert(BackfillNoteLinkQualified.new(%{}))
        {:more, chains: 1}
    end
  end

  @doc """
  True while every cluster node writes `qualified`
  (`Links.qualified_writer_level/0` through `Readiness.peers_report/4`, as
  `NoteName.fleet_ready?/1`). `fleet` overrides the gate's collaborators (tests).
  """
  @spec fleet_ready?(keyword()) :: boolean()
  def fleet_ready?(fleet \\ []) do
    opts = Keyword.merge([sync: fn -> :ok end], fleet)

    case Readiness.peers_report(Links, :qualified_writer_level, 1, opts) do
      :ok ->
        true

      {reason, node} ->
        Logger.info(
          "note link qualified backfill waiting for the fleet",
          Metadata.with_category(:info, :oban, reason: reason, peer: inspect(node))
        )

        false
    end
  end

  @doc "Records a complete chain walk that fixed `fixed` rows (`WalkMemo`)."
  @spec walked(non_neg_integer()) :: :ok
  def walked(fixed), do: WalkMemo.walked(@last_walk, fixed)

  @doc "Rows a hop fixes at most: the `note_link_qualified_backfill_max_rows` override."
  @spec max_rows() :: pos_integer()
  def max_rows, do: Throttle.positive(:note_link_qualified_backfill_max_rows, @max_rows)

  @doc "Rows a hop fixes a second at most: the `note_link_qualified_backfill_writes_per_s` override."
  @spec writes_per_s() :: pos_integer()
  def writes_per_s,
    do: Throttle.positive(:note_link_qualified_backfill_writes_per_s, @writes_per_s)
end
