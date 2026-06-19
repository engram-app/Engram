defmodule EngramWeb.ApiSpec do
  @moduledoc """
  Root OpenAPI 3.0 document for the Engram REST API.

  Paths are derived from the Phoenix router via `Paths.from_router/1`:
  only controller actions carrying `OpenApiSpex.ControllerSpecs.operation`
  annotations contribute paths, so the spec grows as endpoints are
  annotated. Everything downstream (served spec, openapi.json, the docs
  site) flows from here.
  """
  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias EngramWeb.Router

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Engram API",
        description: "REST API for Engram — notes, search, sync, billing, and MCP.",
        version: to_string(Application.spec(:engram, :vsn) || "dev")
      },
      servers: [
        %Server{url: "https://api.engram.page", description: "Production"}
      ],
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT",
            description: "Clerk/local JWT or OAuth access token."
          },
          "apiKey" => %SecurityScheme{
            type: "apiKey",
            in: "header",
            name: "authorization",
            description: "Personal API key (Bearer <key>)."
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
