defmodule EngramWeb.Schemas.User do
  @moduledoc "The authenticated user's profile."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "User",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      email: %Schema{type: :string, format: :email},
      role: %Schema{type: :string, example: "user"},
      display_name: %Schema{type: :string, nullable: true},
      locale: %Schema{
        type: :string,
        nullable: true,
        description: "UI language as a BCP 47 tag, as last reported by a client.",
        example: "pt-BR"
      },
      analytics_id: %Schema{
        type: :string,
        description:
          "Keyed pseudonymous identifier (HMAC of the user's email) for client-side " <>
            "analytics identify calls. See Engram.Observability.PostHog.analytics_id/1."
      }
    },
    required: [:id, :email, :analytics_id]
  })
end

defmodule EngramWeb.Schemas.UserResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UserResponse",
    type: :object,
    properties: %{user: EngramWeb.Schemas.User},
    required: [:user]
  })
end

defmodule EngramWeb.Schemas.UpdateProfileRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UpdateProfileRequest",
    type: :object,
    properties: %{
      display_name: %Schema{type: :string, nullable: true},
      locale: %Schema{type: :string, description: "BCP 47 language tag", example: "pt-BR"}
    },
    example: %{"display_name" => "Ada Lovelace", "locale" => "en"}
  })
end

defmodule EngramWeb.Schemas.DeleteAccountRequest do
  @moduledoc "Self-serve account deletion requires the account password."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DeleteAccountRequest",
    type: :object,
    properties: %{password: %Schema{type: :string, format: :password}},
    required: [:password],
    example: %{"password" => "correct horse battery staple"}
  })
end

defmodule EngramWeb.Schemas.OkFlag do
  @moduledoc "Generic success acknowledgement."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "OkFlag",
    type: :object,
    properties: %{ok: %Schema{type: :boolean, example: true}},
    required: [:ok]
  })
end

defmodule EngramWeb.Schemas.StorageUsage do
  @moduledoc "Per-user attachment storage usage and caps (bytes)."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "StorageUsage",
    type: :object,
    properties: %{
      used_bytes: %Schema{type: :integer},
      file_count: %Schema{type: :integer},
      max_bytes: %Schema{type: :integer},
      max_attachment_bytes: %Schema{
        type: :integer,
        description: "Per-file cap for the user's plan."
      }
    },
    required: [:used_bytes, :file_count, :max_bytes, :max_attachment_bytes]
  })
end
