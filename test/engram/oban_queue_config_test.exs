defmodule Engram.ObanQueueConfigTest do
  # Guard: every Oban worker must enqueue to a queue that is actually
  # registered in `config :engram, Oban, queues: [...]`. A worker pointed
  # at an unregistered queue has no producer on any node, so its jobs sit
  # `available` forever and never execute (the orphaned-queue failure mode
  # that stranded :indexing + :default in prod). Catches it at compile/CI
  # time instead of via a Grafana backlog days later.
  use ExUnit.Case, async: true

  test "every Oban worker's queue is registered in the Oban queues config" do
    configured =
      :engram
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:queues)
      |> Keyword.keys()
      |> MapSet.new()

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
               "  #{inspect(mod)} -> :#{q}"
             end)
  end

  defp oban_worker?(mod) do
    Oban.Worker in (mod.module_info(:attributes)[:behaviour] || [])
  end

  # Pull the worker's actual queue from a built changeset so it reflects the
  # real `use Oban.Worker, queue:` value (no reliance on private internals).
  defp worker_queue(mod) do
    mod.new(%{})
    |> Ecto.Changeset.get_field(:queue)
    |> String.to_existing_atom()
  end
end
