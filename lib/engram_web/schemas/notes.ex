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
  alias OpenApiSpex.Schema
  require OpenApiSpex

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
    required: [:path, :mtime],
    example: %{
      "path" => "Projects/Engram.md",
      "content" => "# Engram\n\nAn AI-powered personal knowledge base.\n",
      "mtime" => 1_718_900_000.0,
      "tags" => ["project", "ai"]
    }
  })
end

defmodule EngramWeb.Schemas.RenameRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RenameRequest",
    type: :object,
    properties: %{old_path: %Schema{type: :string}, new_path: %Schema{type: :string}},
    required: [:old_path, :new_path],
    example: %{
      "old_path" => "Projects/Engram.md",
      "new_path" => "Archive/Engram.md"
    }
  })
end

defmodule EngramWeb.Schemas.RenameNoteResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

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
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AppendRequest",
    type: :object,
    properties: %{path: %Schema{type: :string}, text: %Schema{type: :string}},
    required: [:path, :text],
    example: %{
      "path" => "Daily/2026-06-20.md",
      "text" => "\n- [ ] Ship the API docs coverage gate\n"
    }
  })
end

defmodule EngramWeb.Schemas.AppendResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

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
  alias OpenApiSpex.Schema
  require OpenApiSpex

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
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BatchUpsertRequest",
    type: :object,
    properties: %{
      notes: %Schema{type: :array, maxItems: 100, items: EngramWeb.Schemas.UpsertNoteRequest}
    },
    required: [:notes],
    example: %{
      "notes" => [
        %{
          "path" => "Projects/Engram.md",
          "content" => "# Engram\n\nAn AI-powered personal knowledge base.\n",
          "mtime" => 1_718_900_000.0,
          "tags" => ["project", "ai"]
        },
        %{
          "path" => "Daily/2026-06-20.md",
          "content" => "## 2026-06-20\n\n- Shipped the batch upsert endpoint.\n",
          "mtime" => 1_718_900_100.0
        }
      ]
    }
  })
end

defmodule EngramWeb.Schemas.BatchUpsertResult do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

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
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BatchUpsertResponse",
    type: :object,
    properties: %{results: %Schema{type: :array, items: EngramWeb.Schemas.BatchUpsertResult}},
    required: [:results]
  })
end

defmodule EngramWeb.Schemas.BatchIdsRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BatchIdsRequest",
    type: :object,
    properties: %{ids: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}}},
    required: [:ids],
    example: %{
      "ids" => [
        "9f1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d",
        "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      ]
    }
  })
end

defmodule EngramWeb.Schemas.BatchMoveNotesRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BatchMoveNotesRequest",
    type: :object,
    properties: %{
      ids: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}},
      target_folder_id: %Schema{type: :string, description: "Folder UUID or \"root\"."}
    },
    required: [:ids, :target_folder_id],
    example: %{
      "ids" => [
        "9f1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d",
        "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
      ],
      "target_folder_id" => "7c8d9e0f-1a2b-3c4d-5e6f-7a8b9c0d1e2f"
    }
  })
end
