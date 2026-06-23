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

  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :rate_limiter)
    poll_rate = Keyword.get(opts, :rate_limiter_poll_rate, 5_000)

    Polling.build(
      :engram_rate_limiter_polling_metrics,
      poll_rate,
      {__MODULE__, :execute_cluster_metrics, []},
      [
        last_value(
          metric_prefix ++ [:cluster, :peers],
          event_name: [:engram, :rate_limiter, :cluster],
          measurement: :peers,
          description:
            "Connected BEAM peer nodes. 0 = standalone/unclustered → rate-limit counts are per-node only."
        ),
        last_value(
          metric_prefix ++ [:cluster, :distributed],
          event_name: [:engram, :rate_limiter, :cluster],
          measurement: :distributed,
          description:
            "1 when the cluster-shared :distributed_ets backend is active, else 0 (per-node :ets)."
        )
      ]
    )
  end

  @doc """
  Polled emitter for cluster status. Reports the BEAM peer count and whether the
  cluster-shared backend is active, so the limiter telemetry is interpretable in
  BOTH clustered and standalone deploys (self-host or unclustered prod):

    * standalone → `peers: 0, distributed: 0`
    * clustered  → `peers: >=1, distributed: 1`
  """
  @spec execute_cluster_metrics() :: :ok
  def execute_cluster_metrics do
    :telemetry.execute(
      [:engram, :rate_limiter, :cluster],
      %{peers: length(Node.list()), distributed: distributed_flag()},
      %{}
    )
  end

  defp distributed_flag do
    if EngramWeb.RateLimiter.backend() == :distributed_ets, do: 1, else: 0
  end
end
