defmodule EngramWeb.Schemas.Folder do
  @moduledoc "A folder node."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Folder",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid, nullable: true},
      name: %Schema{type: :string},
      count: %Schema{type: :integer},
      parent_id: %Schema{type: :string, format: :uuid, nullable: true}
    },
    required: [:name]
  })
end

defmodule EngramWeb.Schemas.FoldersResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "FoldersResponse",
    type: :object,
    properties: %{folders: %Schema{type: :array, items: EngramWeb.Schemas.Folder}},
    required: [:folders]
  })
end

defmodule EngramWeb.Schemas.FolderNamesResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "FolderNamesResponse",
    type: :object,
    properties: %{
      folders: %Schema{
        type: :array,
        items: %Schema{type: :object, properties: %{name: %Schema{type: :string}}}
      }
    },
    required: [:folders]
  })
end

defmodule EngramWeb.Schemas.FolderListResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "FolderListResponse",
    type: :object,
    properties: %{
      folder: %Schema{type: :string},
      notes: %Schema{type: :array, items: EngramWeb.Schemas.NoteMeta}
    },
    required: [:folder, :notes]
  })
end

defmodule EngramWeb.Schemas.FolderNotesResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "FolderNotesResponse",
    type: :object,
    properties: %{notes: %Schema{type: :array, items: EngramWeb.Schemas.NoteMeta}},
    required: [:notes]
  })
end

defmodule EngramWeb.Schemas.CreateFolderRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateFolderRequest",
    type: :object,
    properties: %{folder: %Schema{type: :string}},
    required: [:folder],
    example: %{"folder" => "Projects/Engram"}
  })
end

defmodule EngramWeb.Schemas.BatchCreateFoldersRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BatchCreateFoldersRequest",
    type: :object,
    properties: %{folders: %Schema{type: :array, items: %Schema{type: :string}, maxItems: 500}},
    required: [:folders],
    example: %{"folders" => ["Projects/Engram", "Archive"]}
  })
end

defmodule EngramWeb.Schemas.BatchCreateFoldersResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BatchCreateFoldersResponse",
    type: :object,
    properties: %{
      folders: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            input: %Schema{type: :string, description: "The folder as sent"},
            name: %Schema{type: :string, description: "The folder as stored (sanitized)"},
            count: %Schema{type: :integer}
          },
          required: [:input, :name]
        }
      },
      rejected: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "Inputs that sanitize to the vault root; nothing was created for them"
      }
    },
    required: [:folders, :rejected]
  })
end

defmodule EngramWeb.Schemas.FolderResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "FolderResponse",
    type: :object,
    properties: %{folder: EngramWeb.Schemas.Folder},
    required: [:folder]
  })
end

defmodule EngramWeb.Schemas.FolderRenameResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "FolderRenameResponse",
    type: :object,
    properties: %{
      renamed: %Schema{type: :boolean},
      old_path: %Schema{type: :string},
      new_path: %Schema{type: :string},
      count: %Schema{type: :integer}
    }
  })
end

defmodule EngramWeb.Schemas.BatchMoveFoldersRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BatchMoveFoldersRequest",
    type: :object,
    properties: %{
      ids: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}},
      target_parent_id: %Schema{type: :string, description: "Parent folder UUID or \"root\"."},
      target_parent: %Schema{
        type: :string,
        description:
          "Destination parent folder path (alternative to target_parent_id; \"\" = top level). " <>
            "Use this to re-parent under a derived folder that has no marker."
      }
    },
    required: [:ids],
    example: %{
      "ids" => [
        "3c4d5e6f-7a8b-9c0d-1e2f-3a4b5c6d7e8f",
        "4d5e6f7a-8b9c-0d1e-2f3a-4b5c6d7e8f90"
      ],
      "target_parent_id" => "root"
    }
  })
end
