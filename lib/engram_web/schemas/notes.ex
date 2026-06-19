defmodule EngramWeb.Schemas.NoteResponse do
  @moduledoc false
  require OpenApiSpex
  OpenApiSpex.schema(%{
    title: "NoteResponse",
    type: :object,
    properties: %{note: EngramWeb.Schemas.Note},
    required: [:note]
  })
end

defmodule EngramWeb.Schemas.UpsertNoteRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "UpsertNoteRequest",
    type: :object,
    properties: %{
      path: %Schema{type: :string},
      content: %Schema{type: :string},
      mtime: %Schema{type: :number, format: :float},
      version: %Schema{type: :integer, nullable: true},
      title: %Schema{type: :string, nullable: true},
      folder: %Schema{type: :string, nullable: true},
      tags: %Schema{type: :array, items: %Schema{type: :string}}
    },
    required: [:path, :mtime]
  })
end

defmodule EngramWeb.Schemas.RenameRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "RenameRequest",
    type: :object,
    properties: %{old_path: %Schema{type: :string}, new_path: %Schema{type: :string}},
    required: [:old_path, :new_path]
  })
end

defmodule EngramWeb.Schemas.RenameNoteResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "RenameNoteResponse",
    type: :object,
    properties: %{
      renamed: %Schema{type: :boolean},
      old_path: %Schema{type: :string},
      new_path: %Schema{type: :string},
      note: EngramWeb.Schemas.Note
    }
  })
end

defmodule EngramWeb.Schemas.AppendRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "AppendRequest",
    type: :object,
    properties: %{path: %Schema{type: :string}, text: %Schema{type: :string}},
    required: [:path, :text]
  })
end

defmodule EngramWeb.Schemas.AppendResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "AppendResponse",
    type: :object,
    properties: %{
      created: %Schema{type: :boolean},
      path: %Schema{type: :string},
      note: EngramWeb.Schemas.Note
    }
  })
end

defmodule EngramWeb.Schemas.ChangesResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "ChangesResponse",
    type: :object,
    properties: %{
      changes: %Schema{
        type: :array,
        description: "Note objects (content present only when fields=all).",
        items: EngramWeb.Schemas.Note
      },
      server_time: %Schema{type: :string, format: :"date-time"},
      has_more: %Schema{type: :boolean},
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule EngramWeb.Schemas.BatchUpsertRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "BatchUpsertRequest",
    type: :object,
    properties: %{
      notes: %Schema{type: :array, maxItems: 100, items: EngramWeb.Schemas.UpsertNoteRequest}
    },
    required: [:notes]
  })
end

defmodule EngramWeb.Schemas.BatchUpsertResult do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "BatchUpsertResult",
    type: :object,
    properties: %{
      path: %Schema{type: :string},
      status: %Schema{type: :string, enum: ["ok", "conflict", "error"]},
      id: %Schema{type: :string, format: :uuid, nullable: true},
      version: %Schema{type: :integer, nullable: true},
      content_hash: %Schema{type: :string, nullable: true},
      server_path: %Schema{type: :string, nullable: true},
      errors: %Schema{type: :object, nullable: true},
      server_note: %Schema{oneOf: [EngramWeb.Schemas.Note], nullable: true}
    }
  })
end

defmodule EngramWeb.Schemas.BatchUpsertResponse do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "BatchUpsertResponse",
    type: :object,
    properties: %{results: %Schema{type: :array, items: EngramWeb.Schemas.BatchUpsertResult}},
    required: [:results]
  })
end

defmodule EngramWeb.Schemas.BatchIdsRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "BatchIdsRequest",
    type: :object,
    properties: %{ids: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}}},
    required: [:ids]
  })
end

defmodule EngramWeb.Schemas.BatchMoveNotesRequest do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema
  OpenApiSpex.schema(%{
    title: "BatchMoveNotesRequest",
    type: :object,
    properties: %{
      ids: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}},
      target_folder_id: %Schema{type: :string, description: "Folder UUID or \"root\"."}
    },
    required: [:ids, :target_folder_id]
  })
end
