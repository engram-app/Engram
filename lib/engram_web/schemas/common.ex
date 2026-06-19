defmodule EngramWeb.Schemas.Note do
  @moduledoc "A note with its full content."
  require OpenApiSpex
  alias OpenApiSpex.Schema

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
      updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
    },
    required: [:path]
  })
end

defmodule EngramWeb.Schemas.NoteMeta do
  @moduledoc "A note without its content (list/changes responses)."
  require OpenApiSpex
  alias OpenApiSpex.Schema

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
      updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
    },
    required: [:path]
  })
end

defmodule EngramWeb.Schemas.Error do
  @moduledoc "Generic error body."
  require OpenApiSpex
  alias OpenApiSpex.Schema

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
  require OpenApiSpex
  alias OpenApiSpex.Schema

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
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "DeletedFlag",
    type: :object,
    properties: %{deleted: %Schema{type: :boolean, example: true}},
    required: [:deleted]
  })
end

defmodule EngramWeb.Schemas.DeletedCount do
  @moduledoc "Batch-delete count."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "DeletedCount",
    type: :object,
    properties: %{deleted: %Schema{type: :integer, example: 3}},
    required: [:deleted]
  })
end

defmodule EngramWeb.Schemas.MovedCount do
  @moduledoc "Batch-move count."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "MovedCount",
    type: :object,
    properties: %{moved: %Schema{type: :integer, example: 3}},
    required: [:moved]
  })
end
