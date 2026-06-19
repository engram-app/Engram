defmodule EngramWeb.Schemas do
  @moduledoc """
  Reusable OpenApiSpex response/request schema modules.

  Start small: only the schemas referenced by annotated controllers live
  here. Add a module per response shape as endpoints are annotated.
  """

  defmodule HealthStatus do
    @moduledoc "Liveness/readiness response from /api/health[/deep]."
    alias OpenApiSpex.Schema
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HealthStatus",
      description: "Service health status.",
      type: :object,
      properties: %{
        status: %Schema{type: :string, example: "ok", description: "ok | degraded"},
        version: %Schema{type: :string, example: "0.5.464", description: "Running app version"},
        checks: %Schema{
          type: :object,
          description: "Per-dependency status map (present on /deep only)",
          additionalProperties: %Schema{type: :string}
        }
      },
      required: [:status],
      example: %{"status" => "ok", "version" => "0.5.464"}
    })
  end
end
