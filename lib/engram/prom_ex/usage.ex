defmodule Engram.PromEx.Usage do
  @moduledoc """
  PromEx plugin for usage-cap enforcement counters. Makes the daily
  token-bucket cap (`Engram.Usage.DailyCap`) observable on the scraped
  `/metrics` endpoint.

  Events + metrics:

    * `[:engram, :usage, :daily_cap]` → `..._daily_cap_total`, tags
      `[:kind, :decision]` — every cap check, split by bucket `kind`
      (e.g. `inapp_search`) and `decision` (`allow` | `deny` |
      `fail_open`). `fail_open` is the outage signal: the DB errored and
      the call allowed through, so a non-trivial rate there means the cap
      is not actually enforcing.

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
