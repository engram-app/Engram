defmodule EngramWeb.Schemas.ManifestEntry do
  @moduledoc "A single manifest row: decrypted path + content hash."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ManifestEntry",
    type: :object,
    properties: %{
      id: %Schema{
        type: :string,
        format: :uuid,
        description: "Stable note/attachment id — lets a client reconcile its path↔id map."
      },
      path: %Schema{type: :string},
      content_hash: %Schema{type: :string, nullable: true}
    },
    required: [:id, :path]
  })
end

defmodule EngramWeb.Schemas.ManifestResponse do
  @moduledoc "Full vault manifest — every live note and attachment path + hash."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ManifestResponse",
    type: :object,
    properties: %{
      notes: %Schema{type: :array, items: EngramWeb.Schemas.ManifestEntry},
      attachments: %Schema{type: :array, items: EngramWeb.Schemas.ManifestEntry},
      total_notes: %Schema{type: :integer},
      total_attachments: %Schema{type: :integer},
      change_seq: %Schema{type: :integer, description: "Current per-vault sequence watermark."}
    },
    required: [:notes, :attachments, :total_notes, :total_attachments, :change_seq]
  })
end

defmodule EngramWeb.Schemas.EmbedStatusResponse do
  @moduledoc "Embedding/index progress counts for the user's notes."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "EmbedStatusResponse",
    type: :object,
    properties: %{
      total: %Schema{type: :integer},
      indexed: %Schema{
        type: :integer,
        description: "Notes whose embedding matches current content."
      },
      pending: %Schema{type: :integer, description: "Notes awaiting (re)embedding."}
    },
    required: [:total, :indexed, :pending]
  })
end
