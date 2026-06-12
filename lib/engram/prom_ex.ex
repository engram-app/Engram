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
      Engram.PromEx.Sync,
      Engram.PromEx.Search,
      Engram.PromEx.Mcp,
      Engram.PromEx.Crypto
    ]
  end

  @impl true
  def dashboards, do: []
end
