defmodule Engram.PromExObanPollGroupTest do
  # Guard: a node that runs no Oban queues must not PUBLISH Oban queue-length
  # metrics.
  #
  # PromEx's `:oban_queue_poll_metrics` group polls Postgres for per-queue
  # counts and records them as `last_value` gauges. `last_value` never expires:
  # once a node writes a sample, that sample is served on every scrape until the
  # node writes a new one. A poller that stops therefore does not go quiet — it
  # freezes, and keeps asserting a number that was true once.
  #
  # `ENGRAM_NODE_ROLE=web` sets `queues: false`, which is exactly that state.
  # Measured in prod 2026-08-28: web nodes served
  # available=136 / scheduled=358 / executing=5 for 40+ minutes while the
  # database held ZERO embed jobs in those states. It read as a wedged queue and
  # cost a live incident investigation. See #1497.
  #
  # The fix is to drop the group on a queueless node rather than let it publish
  # a number it cannot observe. These tests pin the two halves that make that
  # true: the config key PromEx actually reads, and the role gate that sets it.
  use ExUnit.Case, async: true

  @poll_group :oban_queue_poll_metrics

  describe "queueless nodes" do
    test "the web role drops the Oban queue-poll metrics group" do
      dropped = drop_groups_for(%{"ENGRAM_NODE_ROLE" => "web"})

      assert @poll_group in dropped,
             "a web node runs `queues: false` and cannot observe queue depth, but it would\n" <>
               "still publish #{inspect(@poll_group)}. PromEx gauges are `last_value`, so the\n" <>
               "final sample it writes is scraped forever — see #1497.\n" <>
               "Got drop_metrics_groups: #{inspect(dropped)}"
    end
  end

  describe "nodes that DO run queues" do
    test "the worker role keeps the group — it is the only node that can observe queue depth" do
      dropped = drop_groups_for(%{"ENGRAM_NODE_ROLE" => "worker"})

      refute @poll_group in dropped,
             "the worker executes every queue; dropping its poller would leave NO node\n" <>
               "publishing queue depth at all, which is worse than a stale one."
    end

    test "an unset role keeps the group — self-host and dev run queues on every node" do
      dropped = drop_groups_for(%{})

      refute @poll_group in dropped,
             "an unset ENGRAM_NODE_ROLE means a single unsplit node running all queues.\n" <>
               "It observes them correctly and must keep publishing."
    end
  end

  # config/runtime.exs cannot call this function: it is evaluated by a
  # Config.Provider during release boot, before any application starts, so
  # calling app code from it is a boot-crash risk. It therefore carries the
  # LITERAL list, and this test is what stops the two drifting apart — a
  # duplicated constant with nothing checking it is how the stale gauge comes
  # back with the policy function still looking correct.
  test "config/runtime.exs drops exactly what the policy function says, for the web role" do
    source = File.read!(Path.join(__DIR__, "../../config/runtime.exs"))

    expected = drop_groups_for(%{"ENGRAM_NODE_ROLE" => "web"})
    literal = "drop_metrics_groups: #{inspect(expected)}"

    assert source =~ literal,
           "config/runtime.exs must set `#{literal}` in the ENGRAM_NODE_ROLE=web branch.\n" <>
             "Engram.PromEx.drop_metrics_groups/1 returns #{inspect(expected)}, but runtime.exs\n" <>
             "does not contain that literal — the policy and the thing that applies it have\n" <>
             "drifted, and a web node will publish a gauge it cannot observe. See #1497."
  end

  # The policy itself, as a pure function of the environment.
  defp drop_groups_for(env), do: Engram.PromEx.drop_metrics_groups(env)
end
