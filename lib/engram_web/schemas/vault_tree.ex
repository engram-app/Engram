defmodule EngramWeb.Schemas.VaultTreeNote do
  @moduledoc "A note entry in the vault tree (no content, title, tags or hash — see controller moduledoc)."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "VaultTreeNote",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      path: %Schema{type: :string},
      created_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :path, :created_at, :updated_at]
  })
end

defmodule EngramWeb.Schemas.VaultTreeAttachment do
  @moduledoc "An attachment entry in the vault tree."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "VaultTreeAttachment",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      path: %Schema{type: :string},
      mime_type: %Schema{type: :string, nullable: true},
      size_bytes: %Schema{type: :integer},
      mtime: %Schema{type: :number, format: :float, description: "Client mtime (epoch seconds)"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :path, :size_bytes, :mtime, :updated_at]
  })
end

defmodule EngramWeb.Schemas.VaultTreeResponse do
  @moduledoc "Every folder, note and attachment the file tree renders, in one response."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "VaultTreeResponse",
    type: :object,
    properties: %{
      folders: %Schema{type: :array, items: EngramWeb.Schemas.Folder},
      notes: %Schema{type: :array, items: EngramWeb.Schemas.VaultTreeNote},
      attachments: %Schema{type: :array, items: EngramWeb.Schemas.VaultTreeAttachment},
      change_seq: %Schema{type: :integer, description: "Current per-vault sequence watermark."}
    },
    required: [:change_seq]
  })
end
