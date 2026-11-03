defmodule Engram.PromEx.ObanTest do
  # The queue-depth poll feeds the `oban-queue-stalled` and `oban-no-consumer`
  # alerts (engram-infra grafana_alerts.tf), which select
  # `engram_prom_ex_oban_queue_length_count{state="available"|"executing"}`.
  # These pin that the cheap poll keeps that series shape while never reading
  # terminal (completed/discarded/cancelled) rows.
  use Engram.DataCase, async: false

  alias Engram.PromEx.Oban, as: Plugin
  alias Engram.Repo

  @event [:prom_ex, :plugin, :oban, :queue, :length, :count]
  @pending ~w(suspended scheduled available executing retryable)

  setup do
    test_pid = self()
    handler = "oban-poll-test-#{inspect(make_ref())}"

    :telemetry.attach(
      handler,
      @event,
      fn _e, %{count: count}, meta, _ -> send(test_pid, {:depth, meta, count}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    conf = Oban.Config.new(repo: Repo, queues: [embed: 5, maintenance: 1])
    {:ok, conf: conf}
  end

  defp job!(queue, state) do
    %{}
    |> Oban.Job.new(worker: "Engram.FakeWorker", queue: queue)
    |> Ecto.Changeset.put_change(:state, state)
    |> Repo.insert!(skip_tenant_check: true)
  end

  defp collect(acc \\ %{}) do
    receive do
      {:depth, meta, count} -> collect(Map.put(acc, {meta.name, meta.queue, meta.state}, count))
    after
      100 -> acc
    end
  end

  test "emits the alert series (available, executing) with the original labels", %{conf: conf} do
    job!("embed", "available")
    job!("embed", "available")
    job!("embed", "executing")

    seen = Plugin.emit_queue_depth(conf) && collect()

    assert seen[{"Oban", "embed", "available"}] == 2
    assert seen[{"Oban", "embed", "executing"}] == 1
  end

  test "terminal states are neither queried nor emitted", %{conf: conf} do
    for state <- ~w(completed discarded cancelled), do: job!("embed", state)

    seen = Plugin.emit_queue_depth(conf) && collect()

    assert seen |> Map.keys() |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(@pending)

    assert Enum.all?(Map.values(seen), &(&1 == 0))

    # Literal states (no bind parameter) so the planner matches Oban's
    # state-leading index at plan time.
    {sql, params} = Repo.to_sql(:all, Plugin.pending_query())
    assert params == []

    assert sql =~
             ~s{WHERE (o0."state" IN ('suspended','scheduled','available','executing','retryable'))}
  end

  test "a configured queue with no rows reads 0 for every pending state", %{conf: conf} do
    seen = Plugin.emit_queue_depth(conf) && collect()

    for queue <- ~w(embed maintenance), state <- @pending do
      assert seen[{"Oban", queue, state}] == 0, "missing zero for #{queue}/#{state}"
    end

    assert map_size(seen) == 2 * length(@pending)
  end

  test "a queue with pending rows but no config still reports, as the original did", %{conf: conf} do
    job!("orphaned", "available")

    seen = Plugin.emit_queue_depth(conf) && collect()

    assert seen[{"Oban", "orphaned", "available"}] == 1
  end
end
