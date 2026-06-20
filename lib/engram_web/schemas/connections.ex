defmodule EngramWeb.Schemas.ApiKeyMeta do
  @moduledoc "An API key / PAT (metadata only — the secret is shown once at creation)."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ApiKeyMeta",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string},
      created_at: %Schema{type: :string, format: :"date-time", nullable: true},
      last_used: %Schema{type: :string, format: :"date-time", nullable: true}
    },
    required: [:id, :name]
  })
end

defmodule EngramWeb.Schemas.ApiKeysResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ApiKeysResponse",
    type: :object,
    properties: %{keys: %Schema{type: :array, items: EngramWeb.Schemas.ApiKeyMeta}},
    required: [:keys]
  })
end

defmodule EngramWeb.Schemas.CreateApiKeyRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateApiKeyRequest",
    type: :object,
    properties: %{name: %Schema{type: :string}},
    required: [:name],
    example: %{"name" => "CI pipeline"}
  })
end

defmodule EngramWeb.Schemas.ApiKeyCreated do
  @moduledoc "Creation response — `key` is the raw secret, returned only once."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ApiKeyCreated",
    type: :object,
    properties: %{
      key: %Schema{type: :string, description: "Raw secret — store it now; never shown again."},
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string}
    },
    required: [:key, :id, :name]
  })
end

defmodule EngramWeb.Schemas.Connection do
  @moduledoc "An active credential — an OAuth client family or a device family."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Connection",
    type: :object,
    properties: %{
      kind: %Schema{type: :string, example: "oauth"},
      client_id: %Schema{type: :string, nullable: true},
      key_id: %Schema{type: :string, nullable: true},
      name: %Schema{type: :string, nullable: true},
      software_id: %Schema{type: :string, nullable: true},
      software_version: %Schema{type: :string, nullable: true},
      verified: %Schema{type: :boolean, nullable: true},
      logo: %Schema{type: :string, nullable: true},
      slug: %Schema{type: :string, nullable: true},
      vault_id: %Schema{type: :string, format: :uuid, nullable: true},
      vault_name: %Schema{type: :string, nullable: true},
      scope: %Schema{type: :string, nullable: true},
      last_used_at: %Schema{type: :string, format: :"date-time", nullable: true},
      connected_at: %Schema{type: :string, format: :"date-time", nullable: true},
      first_user_agent: %Schema{type: :string, nullable: true},
      first_ip: %Schema{type: :string, nullable: true},
      redirect_uris: %Schema{type: :array, nullable: true, items: %Schema{type: :string}}
    },
    required: [:kind]
  })
end

defmodule EngramWeb.Schemas.ConnectionsList do
  @moduledoc "A flat array of the user's active connections."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ConnectionsList",
    type: :array,
    items: EngramWeb.Schemas.Connection
  })
end

defmodule EngramWeb.Schemas.CreatePatRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreatePatRequest",
    type: :object,
    properties: %{name: %Schema{type: :string}},
    required: [:name],
    example: %{"name" => "Claude Desktop"}
  })
end
