defmodule Engram.Workers.EmbedNote.CrashGuard do
  @moduledoc """
  Stops one note from crash-looping the node that embeds it.

  Prod, 2026-10-03: a 2.6 MB imported note OOM-killed the worker every 1-14 min
  for six hours. A hard kill never returns, so EmbedNote's poison cooldown
  never fired; Oban's Lifeline re-queued the orphan without recording an error
  and ReconcileEmbeddings kept enqueuing fresh jobs.

  Dead-man stamp on the note row. `stamp/1` writes who started an attempt (this
  node and VM incarnation) and for which content, right before embedding; a
  success clears it (`clear/1`) and `release/2` removes it on any other return. A stamp
  still present when the next attempt starts, left by a runner that is no
  longer alive, is ONE death charged to THIS note: per-note, so jobs that merely
  shared the dying node are not blamed for the culprit.

    * 1st death: the note re-runs alone in the `embed_isolated` queue
      (concurrency 1). A note that was only collateral succeeds there and its
      count resets.
    * 2nd death: quarantine. `embed_retry_after` is set to
      `cooldown_seconds/1` (6h, doubling per further death, capped at 7 days),
      the note's other pending EmbedNote jobs are cancelled, and
      `embed_crash_quarantined` is logged for the Grafana alert.
    * the count belongs to `embed_started_hash`: editing the note forgives it.
  """

  import Ecto.Query

  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo

  require Logger

  @isolated_queue "embed_isolated"

  # The workers that run EmbedNote's pass, so the ones a quarantine cancels.
  @workers ["Engram.Workers.EmbedNote", "Engram.Workers.RebuildStaleNote"]

  defp worker(%Oban.Job{worker: "Engram.Workers.RebuildStaleNote"}),
    do: Engram.Workers.RebuildStaleNote

  defp worker(_job), do: Engram.Workers.EmbedNote

  # Oban kills an EmbedNote attempt at 10 minutes (EmbedNote.timeout/1), so a
  # stamp older than this cannot belong to a live attempt, whoever wrote it.
  @max_attempt_age_seconds 15 * 60

  @base_cooldown_seconds 21_600
  @max_cooldown_seconds 7 * 86_400

  @incarnation_key {__MODULE__, :incarnation}

  @doc "Called once at boot so every attempt in this VM stamps the same runner id."
  def init do
    :persistent_term.put(
      @incarnation_key,
      Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    )
  end

  @doc """
  This VM's runner id, `node/incarnation`. The incarnation tells a restarted
  self-host node (same node name) from the VM that wrote the stamp.
  """
  def runner_id do
    if :persistent_term.get(@incarnation_key, nil) == nil, do: init()
    "#{node()}/#{:persistent_term.get(@incarnation_key)}"
  end

  def cooldown_seconds(deaths),
    do:
      Engram.Jobs.capped_backoff(
        @base_cooldown_seconds,
        max(deaths - 2, 0),
        @max_cooldown_seconds
      )

  @doc """
  Decide what this attempt does. Returns `:run`, `{:snooze, seconds}` (another
  live attempt holds the note), or `{:cancel, reason}` after recording the
  death and acting on it.
  """
  def check(%Note{} = note, %Oban.Job{queue: queue} = job) do
    same_content? = note.embed_started_hash == note.content_hash
    known = if same_content?, do: note.embed_crashes || 0, else: 0

    cond do
      live_stamp?(note) ->
        # Counted: a stamp an attempt failed to release looks exactly like
        # this, and snoozes the note's every job until it ages out (#2449).
        :telemetry.execute(
          [:engram, :embed, :crash_guard_snooze],
          %{count: 1},
          %{reason: :live_stamp}
        )

        {:snooze, 60}

      dead_stamp?(note) and same_content? and known + 1 >= 2 ->
        quarantine(note, job, known + 1)

      dead_stamp?(note) and same_content? ->
        isolate(note, job, known + 1)

      known >= 2 and future?(note.embed_retry_after) ->
        {:cancel, :quarantined}

      known >= 1 and queue != @isolated_queue ->
        isolate(note, job, known)

      true ->
        :run
    end
  end

  @doc """
  Write the dead-man stamp right before embedding. Returns its `started_at`,
  which `release/2` needs.
  """
  def stamp(%Note{} = note) do
    at = DateTime.utc_now()

    :ok =
      write(note,
        embed_started_at: at,
        embed_started_by: runner_id(),
        embed_started_hash: note.content_hash,
        embed_crashes: if(note.embed_started_hash == note.content_hash, do: note.embed_crashes)
      )

    {:ok, at}
  end

  @doc """
  Remove the stamp once the attempt succeeded, and forgive the crash count.
  Runs inside the index write's transaction.
  """
  def clear(%Note{} = note),
    do: write(note, embed_started_at: nil, embed_started_by: nil, embed_crashes: nil)

  @doc """
  Remove the stamp `stamp/1` wrote at `started_at`, on any return of the
  attempt. Keeps the crash count (the poison cooldown handles graceful
  failures). Matching `started_at` leaves a newer attempt's stamp alone, and
  makes this a no-op once `clear/1` ran.
  """
  def release(%Note{} = note, %DateTime{} = started_at) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(
          from(n in Note,
            where: n.id == ^note.id and n.kind == "note" and n.embed_started_at == ^started_at
          ),
          set: [embed_started_at: nil, embed_started_by: nil]
        )
      end)

    :ok
  end

  defp live_stamp?(note), do: note.embed_started_at != nil and not dead_stamp?(note)

  defp dead_stamp?(%Note{embed_started_at: nil}), do: false

  defp dead_stamp?(%Note{embed_started_at: at, embed_started_by: by}) do
    DateTime.diff(DateTime.utc_now(), at) > @max_attempt_age_seconds or not runner_alive?(by)
  end

  defp runner_alive?(by) when is_binary(by) do
    case String.split(by, "/", parts: 2) do
      [node_name, _incarnation] when node_name != "" ->
        if node_name == to_string(node()),
          do: by == runner_id(),
          else: Enum.any?(Node.list(), &(to_string(&1) == node_name))

      _ ->
        false
    end
  end

  defp runner_alive?(_by), do: false

  defp future?(nil), do: false
  defp future?(at), do: DateTime.compare(at, DateTime.utc_now()) == :gt

  # Re-run by the same worker: a `RebuildStaleNote` stays one, so the rerun
  # keeps its maintenance Voyage purpose (no billable retries, H6) and the
  # rebuild gate (chunker v5 Task 16.3).
  defp isolate(note, %Oban.Job{args: args} = job, deaths) do
    :ok = write(note, embed_started_at: nil, embed_started_by: nil, embed_crashes: deaths)

    {:ok, _} =
      Oban.insert(
        worker(job).new(args, queue: @isolated_queue, unique: Engram.Jobs.unique(:none))
      )

    {:cancel, :isolated_after_node_death}
  end

  defp quarantine(note, %Oban.Job{id: self_id}, deaths) do
    cooldown = cooldown_seconds(deaths)

    # Log first: the alert keys on this line, and the writes below can fail
    # (pool exhaustion right after a crash-loop restart).
    Logger.error(
      "embed_crash_quarantined",
      Metadata.with_category(:error, :search,
        user_id: note.user_id,
        vault_id: note.vault_id,
        note_id: note.id,
        result: %{hard_deaths: deaths},
        cooldown_seconds: cooldown
      )
    )

    :telemetry.execute(
      [:engram, :embed, :crash_quarantine],
      %{count: 1, hard_deaths: deaths, cooldown_seconds: cooldown},
      %{note_id: note.id, user_id: note.user_id}
    )

    _ =
      write(note,
        embed_started_at: nil,
        embed_started_by: nil,
        embed_crashes: deaths,
        embed_retry_after: DateTime.add(DateTime.utc_now(), cooldown, :second),
        embed_budget_parked: nil
      )

    # `@>` so the jsonb GIN index on `args` serves it. Never this job: Oban
    # cancels an executing job by killing its process.
    others =
      from(j in Oban.Job,
        where: j.worker in @workers,
        where: j.state in ~w(available scheduled retryable executing),
        where: fragment("? @> ?", j.args, ^%{"note_id" => to_string(note.id)})
      )

    _ = Oban.cancel_all_jobs(if self_id, do: where(others, [j], j.id != ^self_id), else: others)

    {:cancel, :repeated_node_death}
  end

  defp write(note, set) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id and n.kind == "note"), set: set)
      end)

    :ok
  end
end
