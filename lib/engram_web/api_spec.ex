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

  alias EngramWeb.Router
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server, Tag}

  # OpenAPI document version = the API *contract* version, deliberately NOT
  # the app build version (`Application.spec(:engram, :vsn)`). Tying it to the
  # build would change `openapi.json` on every release bump, breaking the CI
  # drift gate on PRs that touch no API surface. Bump this only when the REST
  # contract changes. (The running build version is still available at
  # GET /api/health.)
  @api_version "1.0.0"

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Engram API",
        description: "REST API for Engram — notes, search, sync, billing, and MCP.",
        version: @api_version
      },
      security: [%{"bearerAuth" => []}],
      servers: [
        %Server{url: "https://api.engram.page", description: "Production"}
      ],
      paths: Paths.from_router(Router),
      tags: [
        %Tag{name: "Notes", description: "Create, read, update, delete, and sync notes."},
        %Tag{name: "Folders", description: "Browse and manage folders."},
        %Tag{name: "Search", description: "Vector, keyword, and hybrid search."},
        %Tag{name: "Tags", description: "List vault tags."}
      ],
      components: %Components{
        # Engram accepts all credentials on the same `Authorization: Bearer`
        # header — Clerk/local JWTs, OAuth access tokens, and personal API
        # keys/PATs alike — so a single http/bearer scheme models auth
        # accurately. (A separate `apiKey` scheme keyed on `authorization`
        # would just duplicate this same header.)
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT",
            description:
              "Sent as `Authorization: Bearer <token>` — a Clerk/local JWT, " <>
                "an OAuth access token, or a personal API key/PAT."
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
