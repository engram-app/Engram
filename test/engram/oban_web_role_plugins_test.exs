defmodule Engram.ObanWebRolePluginsTest do
  # Guard: a web node runs no Oban plugins, so it can never be the Oban leader.
  #
  # Cron, Pruner, Lifeline and the Stager's DB transaction run only on the
  # leader. Before this, any peer could win leadership, and prod showed a web
  # task leading in about 49% of 15-minute windows over 7 days (2026-10-20
  # audit): leadership moved to web whenever the single worker restarted and
  # stayed there until web redeployed, so cron and pruning ran from the pool
  # serving user requests.
  #
  # `plugins: false` is what removes web from the election. In Oban 2.24,
  # `normalize_peer/1` maps `plugins: false` to `Oban.Peers.Isolated` with
  # `leader?: false`, and the service plugins (Pruner/Lifeline/Cron) are not
  # added. Inserts are unaffected: they go through the engine on the Repo and
  # notify through pg_notify, which the worker's notifier receives.
  use ExUnit.Case, async: true

  @runtime Path.join(__DIR__, "../../config/runtime.exs")

  test "Oban with plugins: false is a permanent non-leader with no plugins" do
    conf = Oban.Config.new(repo: Engram.Repo, queues: false, plugins: false)

    assert conf.peer == {Oban.Peers.Isolated, [leader?: false]},
           "Oban no longer maps plugins: false to an isolated non-leader peer.\n" <>
             "A web node could win leadership again. Got: #{inspect(conf.peer)}"

    assert conf.plugins == []
  end

  test "Oban with the base plugin list still elects a leader through the database" do
    base = Application.fetch_env!(:engram, Oban)
    conf = Oban.Config.new(repo: Engram.Repo, queues: false, plugins: base[:plugins])

    refute match?({Oban.Peers.Isolated, _}, conf.peer)
    # 2.24 normalizes the plugins into its own service modules (Oban.Cron, ...).
    assert length(conf.plugins) == 3, inspect(conf.plugins)
  end

  test "the unset-role default (config/config.exs) keeps Cron, Pruner and Lifeline" do
    plugins = Application.fetch_env!(:engram, Oban)[:plugins]

    mods =
      Enum.map(plugins, fn
        {mod, _opts} -> mod
        mod -> mod
      end)

    assert Oban.Plugins.Cron in mods
    assert Oban.Plugins.Pruner in mods
    assert Oban.Plugins.Lifeline in mods
  end

  # runtime.exs sets `plugins: false` on top of the config.exs keyword list.
  # Config deep-merges only when BOTH sides are keyword lists, so `false`
  # replaces the list. If it ever merged instead, web would keep Cron.
  test "a runtime plugins: false replaces the base list rather than merging into it" do
    base = Application.fetch_env!(:engram, Oban)

    merged =
      Config.__merge__(
        [engram: [{Oban, base}]],
        engram: [{Oban, [queues: false, plugins: false]}]
      )

    assert merged[:engram][Oban][:plugins] == false
    assert merged[:engram][Oban][:queues] == false
  end

  # The web arm lives inside the `config_env() == :prod` block, which needs a
  # full prod env to evaluate, so this pins the literal (the same approach as
  # PromExObanPollGroupTest).
  test "config/runtime.exs gives the web role no queues AND no plugins" do
    source = File.read!(@runtime)

    assert source =~ "config :engram, Oban, queues: false, plugins: false",
           "the ENGRAM_NODE_ROLE=web arm of config/runtime.exs must set\n" <>
             "`queues: false, plugins: false`. Without plugins: false a web node can\n" <>
             "win Oban leadership and run Cron/Pruner/Lifeline from the request pool."
  end
end
