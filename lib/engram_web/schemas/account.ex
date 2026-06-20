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
      display_name: %Schema{type: :string, nullable: true}
    },
    required: [:id, :email]
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

defmodule EngramWeb.Schemas.ValidationError do
  @moduledoc "422 body carrying a top-level message and a field→messages detail map."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ValidationError",
    type: :object,
    properties: %{
      error: %Schema{type: :string, example: "validation_failed"},
      details: %Schema{type: :object, description: "field → [messages]"}
    },
    required: [:error]
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
