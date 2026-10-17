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
    properties: %{
      name: %Schema{type: :string},
      vault_access: %Schema{
        type: :object,
        additionalProperties: %Schema{type: :string, enum: ["none", "read", "write"]},
        description:
          "Level per vault id: `none`, `read` (search and read) or `write` (also create, " <>
            "edit, rename and delete notes, and rename or delete the vault). Every id must " <>
            "be one of your vaults. Omit both this and `default_access` for a key on every " <>
            "vault with full write access."
      },
      default_access: %Schema{
        type: :string,
        enum: ["none", "read", "write"],
        description:
          "Level for every vault not listed in `vault_access`, including vaults you create " <>
            "later. Defaults to `none` when `vault_access` is given. `write` also lets the " <>
            "key create vaults. The key must reach at least one vault now or later."
      }
    },
    required: [:name],
    example: %{
      "name" => "CI pipeline",
      "vault_access" => %{"0b7c6a4e-3f1d-4c8e-9a2b-5d6e7f809a1b" => "read"},
      "default_access" => "none"
    }
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
      name: %Schema{type: :string},
      vault_access: %Schema{
        type: :object,
        additionalProperties: %Schema{type: :string, enum: ["none", "read", "write"]},
        description:
          "What the key was granted, read back from storage: a level per listed vault id. " <>
            "Compare it with what you asked for; revoke the key if it is wider."
      },
      default_access: %Schema{
        type: :string,
        enum: ["none", "read", "write"],
        description:
          "The granted level for every vault not in `vault_access`, including later ones."
      }
    },
    required: [:key, :id, :name, :vault_access, :default_access]
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
      family_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description:
          "The grant lineage this row is. One OAuth client can hold several " <>
            "grants over different vault sets, each its own row; pass this to " <>
            "`DELETE /connections/oauth/{client_id}` to revoke only this one. " <>
            "Null for PATs."
      },
      key_id: %Schema{type: :string, nullable: true},
      name: %Schema{type: :string, nullable: true},
      label: %Schema{
        type: :string,
        nullable: true,
        description: "The user's own name for this connection, when they set one."
      },
      software_id: %Schema{type: :string, nullable: true},
      software_version: %Schema{type: :string, nullable: true},
      verified: %Schema{type: :boolean, nullable: true},
      logo: %Schema{type: :string, nullable: true},
      slug: %Schema{type: :string, nullable: true},
      vault_ids: %Schema{
        type: :array,
        nullable: true,
        items: %Schema{type: :string, format: :uuid},
        description:
          "Vaults this connection may reach right now (read or write). Null means every " <>
            "vault, including ones created later. For a connection with per-vault levels " <>
            "this is resolved, not stored: the vaults `vault_levels` shows at read or " <>
            "write. Vaults created later get `new_vaults`, so read both for the full picture."
      },
      vault_names: %Schema{
        type: :array,
        nullable: true,
        items: %Schema{type: :string, nullable: true},
        description:
          "Positional against `vault_ids`. An entry is null when the vault is " <>
            "gone or outside the caller's own scope."
      },
      scope: %Schema{type: :string, nullable: true},
      vault_levels: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            vault_id: %Schema{type: :string, format: :uuid},
            vault_name: %Schema{type: :string, nullable: true},
            level: %Schema{type: :string, enum: ["none", "read", "write"]}
          },
          required: [:vault_id, :level]
        },
        description:
          "What this connection may do in each of your vaults, resolved now. Every vault " <>
            "you can see is listed, `none` included. `read` = search and read, `write` " <>
            "= also change notes and the vault."
      },
      new_vaults: %Schema{
        type: :string,
        enum: ["none", "read", "write"],
        description: "The level this connection gets on vaults you create later."
      },
      last_used_at: %Schema{type: :string, format: :"date-time", nullable: true},
      connected_at: %Schema{type: :string, format: :"date-time", nullable: true},
      first_user_agent: %Schema{type: :string, nullable: true},
      first_ip: %Schema{type: :string, nullable: true},
      redirect_uri: %Schema{
        type: :string,
        nullable: true,
        description:
          "The redirect this grant's authorization code was delivered to. This, " <>
            "not `redirect_uris`, is what decides `verified`. Null for non-OAuth " <>
            "connections and for grants issued before it was recorded."
      },
      redirect_uris: %Schema{
        type: :array,
        nullable: true,
        items: %Schema{type: :string},
        description:
          "Every redirect the client registered. Informational only — a client " <>
            "may register several and choose one per authorization, so a vendor " <>
            "host appearing here proves nothing about this grant."
      },
      cimd_url: %Schema{
        type: :string,
        nullable: true,
        description:
          "CIMD metadata-document URL. Present only for clients that published one, " <>
            "in which case it is the client's public identifier and the reason it can " <>
            "be `verified` despite redirecting to loopback.",
        example: "https://claude.ai/.well-known/oauth-client"
      }
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
    properties: %{
      name: %Schema{type: :string},
      vault_access: %Schema{
        type: :object,
        additionalProperties: %Schema{type: :string, enum: ["none", "read", "write"]},
        description:
          "Level per vault id: `none`, `read` (search and read) or `write` (also create, " <>
            "edit, rename and delete notes, and rename or delete the vault). Every id must " <>
            "be one of your vaults. Omit both this and `default_access` for a key on every " <>
            "vault with full write access."
      },
      default_access: %Schema{
        type: :string,
        enum: ["none", "read", "write"],
        description:
          "Level for every vault not listed in `vault_access`, including vaults you create " <>
            "later. Defaults to `none` when `vault_access` is given. `write` also lets the " <>
            "key create vaults. The key must reach at least one vault now or later."
      }
    },
    required: [:name],
    example: %{"name" => "Claude Desktop"}
  })
end

defmodule EngramWeb.Schemas.UpdateAccessRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UpdateAccessRequest",
    type: :object,
    properties: %{
      vault_access: %Schema{
        type: :object,
        additionalProperties: %Schema{type: :string, enum: ["none", "read", "write"]},
        description:
          "Level per vault id, replacing the credential's current levels. Every id must be " <>
            "one of your active vaults."
      },
      default_access: %Schema{
        type: :string,
        enum: ["none", "read", "write"],
        description:
          "Level for every vault not listed, including vaults you create later. Defaults to " <>
            "`none`. The credential must reach at least one vault now or later."
      }
    },
    example: %{"vault_access" => %{"<vault id>" => "write"}, "default_access" => "none"}
  })
end
