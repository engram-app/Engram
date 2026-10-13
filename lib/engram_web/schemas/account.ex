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
      analytics_id: %Schema{
        type: :string,
        nullable: true,
        description:
          "Keyed pseudonymous identifier (HMAC of the user's email) for client-side " <>
            "analytics identify calls; null when the user opted out. See " <>
            "Engram.Analytics.client_id/1."
      },
      analytics_opt_out: %Schema{
        type: :boolean,
        description: "The user objected to analytics; the client must send nothing."
      }
    },
    required: [:id, :email, :analytics_id, :analytics_opt_out]
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
    properties: %{display_name: %Schema{type: :string, nullable: true}},
    example: %{"display_name" => "Ada Lovelace"}
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
