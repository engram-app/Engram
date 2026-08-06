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
        version: %Schema{
          type: :string,
          example: "0.5.464",
          description:
            "Running app version from mix.exs. Sticky between release-please cuts, so it does NOT change on a non-release deploy — use build_sha to tell what code is actually running."
        },
        build_sha: %Schema{
          type: :string,
          nullable: true,
          example: "e998801f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d",
          description:
            "Commit the running image was built from, baked in at build time. null on local/self-host builds where it was not supplied."
        },
        checks: %Schema{
          type: :object,
          description: "Per-dependency status map (present on /deep only)",
          additionalProperties: %Schema{type: :string}
        }
      },
      required: [:status],
      example: %{"status" => "ok", "version" => "0.5.464", "build_sha" => "e998801"}
    })
  end
end
