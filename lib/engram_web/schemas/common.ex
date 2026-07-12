defmodule EngramWeb.Schemas.Note do
  @moduledoc "A note with its full content."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Note",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid, nullable: true},
      path: %Schema{type: :string, example: "Projects/engram.md"},
      title: %Schema{type: :string, nullable: true},
      folder: %Schema{type: :string, nullable: true},
      tags: %Schema{type: :array, items: %Schema{type: :string}},
      version: %Schema{type: :integer, nullable: true},
      content: %Schema{type: :string},
      content_hash: %Schema{type: :string, nullable: true},
      mtime: %Schema{type: :number, format: :float, description: "Client mtime (epoch seconds)"},
      updated_at: %Schema{type: :string, format: :"date-time", nullable: true},
      type: %Schema{
        type: :string,
        nullable: true,
        description: "OKF frontmatter `type` field"
      },
      description: %Schema{
        type: :string,
        nullable: true,
        description: "OKF frontmatter `description` field"
      },
      resource: %Schema{
        type: :string,
        nullable: true,
        description: "OKF frontmatter `resource` field"
      },
      fm_timestamp: %Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "OKF frontmatter `timestamp`/`modified`/`updated` field"
      },
      fm_created: %Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: "OKF frontmatter `created`/`date` field"
      },
      parse_status: %Schema{
        type: :string,
        enum: ["ok", "degraded"],
        nullable: true,
        description: "Frontmatter parse outcome"
      },
      parse_reason: %Schema{
        type: :object,
        nullable: true,
        description: "Present when parse_status is \"degraded\": {code, message, detail}"
      }
    },
    required: [:path]
  })
end

defmodule EngramWeb.Schemas.NoteMeta do
  @moduledoc "A note without its content (list/changes responses)."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "NoteMeta",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid, nullable: true},
      path: %Schema{type: :string},
      title: %Schema{type: :string, nullable: true},
      folder: %Schema{type: :string, nullable: true},
      tags: %Schema{type: :array, items: %Schema{type: :string}},
      version: %Schema{type: :integer, nullable: true},
      content_hash: %Schema{type: :string, nullable: true},
      mtime: %Schema{type: :number, format: :float},
      updated_at: %Schema{type: :string, format: :"date-time", nullable: true},
      parse_status: %Schema{
        type: :string,
        enum: ["ok", "degraded"],
        nullable: true,
        description: "Frontmatter parse outcome"
      },
      parse_reason: %Schema{
        type: :object,
        nullable: true,
        description: "Present when parse_status is \"degraded\": {code, message, detail}"
      }
    },
    required: [:path]
  })
end

defmodule EngramWeb.Schemas.Error do
  @moduledoc "Generic error body."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Error",
    type: :object,
    properties: %{
      errors: %Schema{
        description: "Error detail — a message string or a field→messages map.",
        oneOf: [%Schema{type: :string}, %Schema{type: :object}]
      }
    }
  })
end

defmodule EngramWeb.Schemas.Conflict do
  @moduledoc "409 version-conflict body; carries the server's authoritative note."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Conflict",
    type: :object,
    properties: %{
      error: %Schema{type: :string, example: "version_conflict"},
      server_note: EngramWeb.Schemas.Note
    }
  })
end

defmodule EngramWeb.Schemas.DeletedFlag do
  @moduledoc "Single-resource delete acknowledgement."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DeletedFlag",
    type: :object,
    properties: %{deleted: %Schema{type: :boolean, example: true}},
    required: [:deleted]
  })
end

defmodule EngramWeb.Schemas.DeletedCount do
  @moduledoc "Batch-delete count."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DeletedCount",
    type: :object,
    properties: %{deleted: %Schema{type: :integer, example: 3}},
    required: [:deleted]
  })
end

defmodule EngramWeb.Schemas.MovedCount do
  @moduledoc "Batch-move count."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MovedCount",
    type: :object,
    properties: %{moved: %Schema{type: :integer, example: 3}},
    required: [:moved]
  })
end

defmodule EngramWeb.Schemas.MessageError do
  @moduledoc "Error body carrying a single machine-readable message under `error`."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MessageError",
    type: :object,
    properties: %{error: %Schema{type: :string, example: "not found"}},
    required: [:error]
  })
end

defmodule EngramWeb.Schemas.LimitError do
  @moduledoc "402 plan-limit body emitted by EngramWeb.LimitResponse."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LimitError",
    type: :object,
    properties: %{
      error: %Schema{type: :string, example: "limit_exceeded"},
      reason: %Schema{type: :string, example: "vaults_cap_exceeded"},
      tier: %Schema{type: :string, nullable: true, example: "free"},
      limit_key: %Schema{type: :string, nullable: true, example: "vaults_cap"},
      limit: %Schema{
        nullable: true,
        description: "Integer or boolean cap.",
        oneOf: [%Schema{type: :integer}, %Schema{type: :boolean}]
      },
      current: %Schema{type: :integer, nullable: true},
      upgrade_url: %Schema{type: :string, nullable: true}
    },
    required: [:error, :reason]
  })
end
