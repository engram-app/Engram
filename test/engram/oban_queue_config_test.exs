defmodule Engram.ObanQueueConfigTest do
  # Guard: every Oban worker must enqueue to a queue that is actually
  # registered in `config :engram, Oban, queues: [...]`. A worker pointed
  # at an unregistered queue has no producer on any node, so its jobs sit
  # `available` forever and never execute (the orphaned-queue failure mode
  # that stranded :cleanup + :indexing + :default in prod). Catches it at
  # compile/CI time instead of via a Grafana backlog days later.
  use ExUnit.Case, async: true

  test "every Oban worker's queue is registered in the Oban queues config" do
    configured = MapSet.new(configured_queues())

    {:ok, modules} = :application.get_key(:engram, :modules)

    offenders =
      for mod <- modules,
          Code.ensure_loaded?(mod),
          oban_worker?(mod),
          queue = worker_queue(mod),
          queue not in configured,
          do: {mod, queue}

    assert offenders == [],
           "Oban workers target queues missing from `config :engram, Oban, queues:`.\n" <>
             "Jobs in an unregistered queue have no producer and never execute.\n" <>
             "Add the queue to config/config.exs (or fix the worker's queue:).\n\n" <>
             Enum.map_join(offenders, "\n", fn {mod, q} ->
               "  #{inspect(mod)} -> #{inspect(q)}"
             end)
  end

  # Regression guard for the 2026-07-03 prod OOM crash-loop. Each *concurrent*
  # Voyage embedding HTTP request (Req → Finch → TLS) holds ~100 MB of off-heap
  # memory (invisible to `:erlang.memory`, released after the request). At
  # `embed: 5`, five simultaneous embeds + a ReconcileEmbeddings backlog blew
  # the 1024 MB Fargate task ceiling → OOM-killed the node every ~2 min. Keeping
  # the embed producer small bounds peak concurrent HTTP fan-out to the embedder.
  # See docs/superpowers/plans/2026-07-02-crdt-oom-compaction-fixes.md.
  test "embed queue concurrency is capped low to bound embedder HTTP off-heap memory" do
    embed_limit = configured_queue_limit(:embed)

    assert is_integer(embed_limit) and embed_limit <= 2,
           "embed queue concurrency must stay <= 2 (got #{inspect(embed_limit)}).\n" <>
             "Each concurrent Voyage embed HTTP request holds ~100 MB off-heap (TLS);\n" <>
             "embed: 5 OOM-killed the 1024 MB prod task on 2026-07-03. Do not raise this\n" <>
             "without also bounding the shared Finch pool + raising the task memory."
  end

  defp configured_queue_limit(queue) do
    Application.fetch_env!(:engram, Oban)[:queues] |> Keyword.get(queue)
  end

  # The configured queue list. `testing: :manual` (config/test.exs) deep-merges
  # into the base `config/config.exs` Oban config, so `:queues` is the real
  # base list here. Guard against an env that stubs it to `false`/`nil` — that
  # would mean NO worker can run, which is itself a misconfiguration, not a
  # silently-empty allowlist that passes the test vacuously.
  defp configured_queues do
    case Application.fetch_env!(:engram, Oban)[:queues] do
      queues when is_list(queues) and queues != [] ->
        Keyword.keys(queues)

      other ->
        flunk(
          "config :engram, Oban, queues: must be a non-empty keyword list, got: " <>
            inspect(other)
        )
    end
  end

  defp oban_worker?(mod) do
    Oban.Worker in (mod.module_info(:attributes)[:behaviour] || [])
  end

  # Pull the worker's actual queue from a built changeset so it reflects the
  # real `use Oban.Worker, queue:` value (no reliance on private internals).
  # If a worker overrides `new/1` to require args and raises on `%{}`, surface
  # that as its own offender instead of crashing the whole guard.
  defp worker_queue(mod) do
    mod.new(%{})
    |> Ecto.Changeset.get_field(:queue)
    |> String.to_existing_atom()
  rescue
    error -> {:could_not_build, Exception.message(error)}
  end
end
