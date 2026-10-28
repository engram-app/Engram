defmodule Engram.DataMigrations.PersonOriginBackfill do
  @moduledoc """
  One-time `country` / `language` / `device_type` backfill of every live Clerk
  user's PostHog person (`PersonOriginSync.backfill/0`), run by the ledger
  instead of an operator rpc.

  `run_pass/0` looks at the backfill jobs in `oban_jobs` (a chain's successor
  is inserted before its predecessor finishes, so a running chain always has an
  incomplete job until its last batch completes):

    * any incomplete one: the chain is running, `:more`;
    * else the newest one completed: the last batch ran, `:done`;
    * else (none, or the newest was discarded/cancelled, a broken chain):
      enqueue a fresh chain, `:more`. A re-run is idempotent and never lowers a
      field's source priority.

  A persistent error (a revoked PostHog key) fails every batch until Oban
  discards it, so each hourly pass restarts one bounded batch and the 7-day
  stuck alert fires: that is the intended signal, not a false `:done`. A
  failed successor insert fails its batch (retried), never ends the chain.

  Enqueue is `unique` on the chain head, so the hourly runner and a
  multi-node boot never start two chains. Pacing and batch size stay in
  `PersonOriginSync`. The Oban Pruner keeps completed jobs 24 h; a runner down
  longer than that would start one more idempotent chain.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Analytics
  alias Engram.Repo
  alias Engram.Workers.PersonOriginSync

  @worker "Engram.Workers.PersonOriginSync"
  @incomplete ~w(available scheduled executing retryable)

  @impl true
  def name, do: "person_origin_backfill"

  @impl true
  def version, do: 1

  # The worker no-ops without PostHog (project key and personal API key); a
  # pass that cannot succeed must not page as stuck (self-host, tests).
  @impl true
  def enabled?, do: Analytics.enabled?() and Analytics.person_reads_enabled?()

  @impl true
  def run_pass do
    case state() do
      :running ->
        {:more, running: true}

      "completed" ->
        :done

      _none_or_broken ->
        case PersonOriginSync.backfill() do
          {:ok, _job} -> {:more, enqueued: true}
          {:error, _} -> :more
        end
    end
  end

  # `:running` when any batch is incomplete (a retryable batch is not the
  # end), else the newest batch's state, else nil.
  defp state do
    jobs =
      from(j in Oban.Job,
        where: j.worker == @worker and fragment("? @> '{\"backfill\": true}'", j.args)
      )

    if Repo.exists?(where(jobs, [j], j.state in @incomplete)),
      do: :running,
      else: Repo.one(from(j in jobs, order_by: [desc: j.id], limit: 1, select: j.state))
  end
end
