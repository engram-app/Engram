defmodule Engram.PromEx.RateLimiter do
  @moduledoc """
  PromEx plugin for the rate limiter (#687). Puts in-house limiter telemetry on
  the scraped `/metrics` endpoint — the bundled plugins don't cover it, and the
  Redis-backed metrics were dropped with #684.

  Events + metrics:

    * `[:engram, :rate_limiter, :hit]` → `..._rate_limiter_hit_total`, tags
      `[:purpose, :result]` — every allow/deny across both backends, emitted at
      the `EngramWeb.RateLimiter` façade. `purpose` is a bounded atom
      (`:preauth | :http | :api_rps | :voyage_embed | :other`); `result` is
      `:allow | :deny`. Alert on deny-rate spikes per purpose.
    * `[:engram, :rate_limiter, :remote_inc]` → `..._rate_limiter_remote_inc_total`,
      tags `[:result]` (`:applied | :dropped`) — cross-node sync signal from the
      `DistributedETS.Listener`. A freshly-joined node starts with an empty ETS
      table and no state handoff, so `rate(...{result="applied"}[1m])` ramping
      from a new task's boot is how you confirm it is warming from peers (and
      `:dropped > 0` means PubSub increments are being lost).

  Cardinality contract: only the bounded tags above. NEVER the bucket key, which
  embeds user_id / ip / request_path.
  """

  use PromEx.Plugin

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :rate_limiter)

    Event.build(
      :engram_rate_limiter_event_metrics,
      [
        counter(
          metric_prefix ++ [:hit, :total],
          event_name: [:engram, :rate_limiter, :hit],
          description: "Rate-limiter decisions by purpose + allow/deny result.",
          tags: [:purpose, :result]
        ),
        counter(
          metric_prefix ++ [:remote_inc, :total],
          event_name: [:engram, :rate_limiter, :remote_inc],
          description: "Cross-node PubSub increments applied vs dropped (DistributedETS).",
          tags: [:result]
        )
      ]
    )
  end
end
