defmodule Engram.PromEx.Oban do
  @moduledoc """
  `PromEx.Plugins.Oban` with a queue-depth poll that reads only pending rows.

  Event metrics (job duration, queue time, producer, circuit breaker) are
  delegated unchanged. The poll is replaced: the bundled one runs
  `SELECT queue, state, count(id) FROM oban_jobs GROUP BY queue, state` with no
  WHERE clause (prom_ex 1.12 `plugins/oban.ex:433`), a seq scan over every
  retained row. In prod it was the #1 app statement: 466k calls since
  2026-09-25, ~10.6 ms and ~1,590 shared blocks (12.4 MB) per call.

  This poll counts only the non-terminal states, as literals so the planner
  serves it from Oban's `(state, queue, ...)` index, and emits the same series:
  `engram_prom_ex_oban_queue_length_count{name, queue, state}`, read by the
  `oban-queue-stalled` / `oban-no-consumer` alerts (available, executing).
  Like the original it emits 0 for every configured queue x state with no rows,
  and still reports a queue that has rows but no config (an orphaned queue).

  `completed`, `discarded` and `cancelled` are no longer published: counting
  them is the full-table read this module exists to avoid.

  The group keeps the name `:oban_queue_poll_metrics`, so the web-role drop in
  `Engram.PromEx.drop_metrics_groups/1` and config/runtime.exs still applies.
  The poll honours `:poll_rate` and `:metric_prefix`; it always polls the
  default `Oban` instance (`:oban_supervisors` applies to event metrics only).
  """
  use PromEx.Plugin

  import Ecto.Query, only: [from: 2]

  @event [:prom_ex, :plugin, :oban, :queue, :length, :count]

  # Same set as `Oban.Job.unique_states(:incomplete)`. Inlined as literals so
  # the statement text and plan stay fixed; a bound `ANY($1)` would also match
  # the state-leading index.
  @pending_states ~w(suspended scheduled available executing retryable)

  @impl true
  defdelegate event_metrics(opts), to: PromEx.Plugins.Oban

  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    Polling.build(
      :oban_queue_poll_metrics,
      Keyword.get(opts, :poll_rate, 5_000),
      {__MODULE__, :execute_queue_metrics, []},
      [
        last_value(
          Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :oban)) ++
            [:queue, :length, :count],
          event_name: @event,
          description: "Jobs in the queue in the designated (non-terminal) state",
          measurement: :count,
          tags: [:name, :queue, :state]
        )
      ]
    )
  end

  @doc false
  def execute_queue_metrics do
    if is_pid(Oban.Registry.whereis(Oban)), do: emit_queue_depth(Oban.config())
    :ok
  end

  @doc false
  def emit_queue_depth(%Oban.Config{} = conf) do
    counts = conf |> Oban.Repo.all(pending_query()) |> Map.new()
    name = PromEx.Utils.normalize_module_name(conf.name)

    zeros =
      for {queue, _} <- conf.queues,
          state <- @pending_states,
          into: %{},
          do: {{to_string(queue), state}, 0}

    zeros
    |> Map.merge(counts)
    |> Enum.each(fn {{queue, state}, count} ->
      :telemetry.execute(@event, %{count: count}, %{name: name, queue: queue, state: state})
    end)
  end

  @doc false
  def pending_query do
    from(j in Oban.Job,
      where: j.state in @pending_states,
      group_by: [j.queue, j.state],
      select: {{j.queue, j.state}, count(j.id)}
    )
  end
end
