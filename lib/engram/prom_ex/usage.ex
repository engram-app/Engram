defmodule Engram.PromEx.Usage do
  @moduledoc """
  PromEx plugin for usage-cap enforcement counters.

  **Currently unemitted.** The daily token-bucket cap this was written for
  (`Engram.Usage.DailyCap`) was deleted and nothing emits
  `[:engram, :usage, :daily_cap]` now, so the metric below stays at zero.
  The definition is kept for when a cap check emits it again.

  Events + metrics:

    * `[:engram, :usage, :daily_cap]` → `..._daily_cap_total`, tags
      `[:kind, :decision]`: cap checks split by bucket `kind` and `decision`
      (`allow` | `deny` | `fail_open`).

  Cardinality contract: `kind` is a fixed bucket label and `decision` is
  one of three atoms — both bounded. NEVER add user_id.
  """

  use PromEx.Plugin

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :usage)

    Event.build(
      :engram_usage_event_metrics,
      [
        counter(
          metric_prefix ++ [:daily_cap, :total],
          event_name: [:engram, :usage, :daily_cap],
          description: "Daily token-bucket cap checks by bucket kind + decision.",
          tags: [:kind, :decision]
        )
      ]
    )
  end
end
