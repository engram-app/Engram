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
    required: [:folder]
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
      target_parent_id: %Schema{type: :string, description: "Parent folder UUID or \"root\"."}
    },
    required: [:ids, :target_parent_id]
  })
end
