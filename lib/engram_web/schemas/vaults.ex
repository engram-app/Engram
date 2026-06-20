defmodule EngramWeb.Schemas.Vault do
  @moduledoc "A vault. `deleted_at`/`purge_at` are non-null only for soft-deleted vaults."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Vault",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      name: %Schema{type: :string},
      description: %Schema{type: :string, nullable: true},
      slug: %Schema{type: :string, nullable: true},
      is_default: %Schema{type: :boolean},
      created_at: %Schema{type: :string, format: :"date-time", nullable: true},
      encrypted: %Schema{
        type: :boolean,
        description: "Always true — vaults are encrypted at rest."
      },
      note_count: %Schema{type: :integer},
      attachment_count: %Schema{type: :integer},
      deleted_at: %Schema{type: :string, format: :"date-time", nullable: true},
      purge_at: %Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "When a soft-deleted vault is hard-purged (deleted_at + 30d)."
      }
    },
    required: [:id, :name]
  })
end

defmodule EngramWeb.Schemas.VaultResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "VaultResponse",
    type: :object,
    properties: %{vault: EngramWeb.Schemas.Vault},
    required: [:vault]
  })
end

defmodule EngramWeb.Schemas.VaultsResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "VaultsResponse",
    type: :object,
    properties: %{
      vaults: %Schema{type: :array, items: EngramWeb.Schemas.Vault},
      suggested_vault_name: %Schema{
        type: :string,
        nullable: true,
        description: "Present only when a `user_code` query param is supplied (device-link flow)."
      }
    },
    required: [:vaults]
  })
end

defmodule EngramWeb.Schemas.CreateVaultRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateVaultRequest",
    type: :object,
    properties: %{
      name: %Schema{type: :string},
      description: %Schema{type: :string, nullable: true},
      is_default: %Schema{type: :boolean}
    },
    required: [:name]
  })
end

defmodule EngramWeb.Schemas.UpdateVaultRequest do
  @moduledoc "Partial update — only supplied fields change."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UpdateVaultRequest",
    type: :object,
    properties: %{
      name: %Schema{type: :string},
      description: %Schema{type: :string, nullable: true},
      is_default: %Schema{type: :boolean}
    }
  })
end

defmodule EngramWeb.Schemas.RegisterVaultRequest do
  @moduledoc "Idempotent register-or-fetch by client_id (plugin first-sync)."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RegisterVaultRequest",
    type: :object,
    properties: %{
      name: %Schema{type: :string},
      client_id: %Schema{type: :string, description: "Client-generated stable vault id."}
    },
    required: [:name, :client_id]
  })
end

defmodule EngramWeb.Schemas.RegisterVaultResponse do
  @moduledoc "A Vault plus a `status` discriminating a fresh create (201) from an existing match (200)."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RegisterVaultResponse",
    type: :object,
    allOf: [
      EngramWeb.Schemas.Vault,
      %Schema{
        type: :object,
        properties: %{status: %Schema{type: :string, enum: ["created", "existing"]}}
      }
    ]
  })
end

defmodule EngramWeb.Schemas.VaultDeleted do
  @moduledoc "Soft-delete acknowledgement."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "VaultDeleted",
    type: :object,
    properties: %{
      deleted: %Schema{type: :boolean, example: true},
      id: %Schema{type: :string, format: :uuid}
    },
    required: [:deleted, :id]
  })
end

defmodule EngramWeb.Schemas.VaultPurged do
  @moduledoc "Hard-purge acknowledgement."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "VaultPurged",
    type: :object,
    properties: %{
      purged: %Schema{type: :boolean, example: true},
      id: %Schema{type: :string, format: :uuid}
    },
    required: [:purged, :id]
  })
end
