defmodule Engram.PromEx do
  @moduledoc """
  PromEx supervisor for Engram. Aggregates telemetry events emitted by
  the BEAM, Phoenix, Ecto, and Oban plugins into a Prometheus-format
  metrics endpoint served at `/metrics` (see EngramWeb.Router).

  The Grafana Agent sidecar in the prod ECS task scrapes that endpoint
  over `localhost`. No outbound remote_write is performed from the app.
  """

  use PromEx, otp_app: :engram

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: EngramWeb.Router, endpoint: EngramWeb.Endpoint},
      Plugins.Ecto,
      Plugins.Oban,
      # engram-app/engram-infra#340 — custom subscribers for in-house
      # telemetry events that the bundled plugins don't cover.
      Engram.PromEx.Voyage,
      Engram.PromEx.Qdrant,
      Engram.PromEx.Search,
      Engram.PromEx.Mcp,
      Engram.PromEx.Crypto,
      Engram.PromEx.Indexing,
      Engram.PromEx.Notes,
      Engram.PromEx.Crdt,
      Engram.PromEx.Reliability,
      Engram.PromEx.Usage,
      Engram.PromEx.RateLimiter,
      Engram.PromEx.Profiling
    ]
  end

  @impl true
  def dashboards, do: []

  # PromEx metric groups this node must NOT publish, given its role.
  #
  # `:oban_queue_poll_metrics` polls Postgres for per-queue job counts and
  # records them as `last_value` gauges. `last_value` does not expire: once a
  # node writes a sample it is served on every scrape until that node writes a
  # new one. So a poller that stops does not go quiet — it FREEZES, and keeps
  # asserting a number that was true once.
  #
  # `ENGRAM_NODE_ROLE=web` sets `queues: false` (config/runtime.exs), which is
  # exactly that state: no queues to poll, nothing to refresh the gauge, and a
  # stale sample published forever. Measured in prod 2026-08-28 — web nodes
  # served available=136 / scheduled=358 / executing=5 for over 40 minutes
  # while the database held ZERO embed jobs in those states. The worker, the
  # only node still running queues, correctly reported 0. Dashboards and the
  # `oban-no-consumer` alert select `max by (queue)` across roles, so they took
  # the frozen web copy and read a 494-job backlog on an empty queue. See #1497.
  #
  # A queueless node has no business publishing a number it cannot observe.
  # Dropping the group makes the series ABSENT rather than wrong, which a
  # dashboard renders as a gap and an alert can treat as no-data — both honest.
  #
  # Only the poll group is dropped. The Oban event metrics (job start/stop/
  # exception) stay registered on every role: they are emitted by execution
  # rather than polled, so a web node simply produces none and no series
  # appears. There is nothing to go stale.
  # Narrow on purpose. `[atom()]` is a supertype of what this can actually
  # return and dialyzer rejects it as `contract_supertype`. Naming the one group
  # also makes the spec the shortest accurate description of the policy: today
  # exactly one group is ever dropped, and widening it is a deliberate edit
  # rather than something that happens by accident.
  @spec drop_metrics_groups(map()) :: [:oban_queue_poll_metrics]
  def drop_metrics_groups(env \\ System.get_env()) do
    case env
         |> Map.get("ENGRAM_NODE_ROLE")
         |> to_string()
         |> String.trim()
         |> String.downcase() do
      "web" -> [:oban_queue_poll_metrics]
      _ -> []
    end
  end
end
