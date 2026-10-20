defmodule EngramWeb.Schemas.AttachmentMeta do
  @moduledoc "Attachment metadata (no bytes). `created_at` is absent in list responses."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentMeta",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid, nullable: true},
      path: %Schema{type: :string, example: "assets/diagram.png"},
      mime_type: %Schema{type: :string, nullable: true},
      size_bytes: %Schema{type: :integer},
      mtime: %Schema{type: :number, format: :float, description: "Client mtime (epoch seconds)"},
      content_hash: %Schema{
        type: :string,
        nullable: true,
        description:
          "Opaque content fingerprint. Stable for identical bytes and scoped to the " <>
            "owning account. Compare against a local copy to decide whether an upload " <>
            "is needed; re-uploading matching bytes is accepted but does no work."
      },
      created_at: %Schema{type: :string, format: :"date-time", nullable: true},
      updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
    },
    required: [:path]
  })
end

defmodule EngramWeb.Schemas.AttachmentWithContent do
  @moduledoc "Attachment metadata plus its base64 bytes (default `show` response)."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentWithContent",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid, nullable: true},
      path: %Schema{type: :string},
      mime_type: %Schema{type: :string, nullable: true},
      size_bytes: %Schema{type: :integer},
      mtime: %Schema{type: :number, format: :float},
      content_hash: %Schema{
        type: :string,
        nullable: true,
        description: "Opaque content fingerprint — see AttachmentMeta.content_hash."
      },
      content_base64: %Schema{type: :string, description: "Base64-encoded file bytes."},
      created_at: %Schema{type: :string, format: :"date-time", nullable: true},
      updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
    },
    required: [:path, :content_base64]
  })
end

defmodule EngramWeb.Schemas.AttachmentResponse do
  @moduledoc false
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentResponse",
    type: :object,
    properties: %{attachment: EngramWeb.Schemas.AttachmentMeta},
    required: [:attachment]
  })
end

defmodule EngramWeb.Schemas.AttachmentsResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentsResponse",
    type: :object,
    properties: %{attachments: %Schema{type: :array, items: EngramWeb.Schemas.AttachmentMeta}},
    required: [:attachments]
  })
end

defmodule EngramWeb.Schemas.UploadAttachmentRequest do
  @moduledoc "Attachments are uploaded as base64 JSON (not multipart)."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UploadAttachmentRequest",
    type: :object,
    properties: %{
      path: %Schema{type: :string},
      content_base64: %Schema{type: :string, description: "Base64-encoded file bytes."},
      mime_type: %Schema{
        type: :string,
        nullable: true,
        description: "Detected from path if omitted."
      }
    },
    required: [:path, :content_base64],
    example: %{
      "path" => "assets/diagram.png",
      "content_base64" =>
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
      "mime_type" => "image/png"
    }
  })
end

defmodule EngramWeb.Schemas.AttachmentRenameResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentRenameResponse",
    type: :object,
    properties: %{
      renamed: %Schema{type: :boolean},
      old_path: %Schema{type: :string},
      new_path: %Schema{type: :string},
      attachment: EngramWeb.Schemas.AttachmentMeta
    }
  })
end

defmodule EngramWeb.Schemas.AttachmentDeleted do
  @moduledoc "Single attachment delete acknowledgement."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentDeleted",
    type: :object,
    properties: %{
      deleted: %Schema{type: :boolean, example: true},
      path: %Schema{type: :string}
    },
    required: [:deleted, :path]
  })
end

defmodule EngramWeb.Schemas.AttachmentBatchMoveRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentBatchMoveRequest",
    type: :object,
    properties: %{
      paths: %Schema{type: :array, items: %Schema{type: :string}},
      target_folder: %Schema{type: :string}
    },
    required: [:paths, :target_folder],
    example: %{
      "paths" => ["assets/diagram.png", "assets/logo.svg"],
      "target_folder" => "archive/assets"
    }
  })
end

defmodule EngramWeb.Schemas.AttachmentBatchDeleteRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentBatchDeleteRequest",
    type: :object,
    properties: %{paths: %Schema{type: :array, items: %Schema{type: :string}}},
    required: [:paths],
    example: %{
      "paths" => ["assets/diagram.png", "assets/old-logo.svg"]
    }
  })
end

defmodule EngramWeb.Schemas.MimeRejected do
  @moduledoc "415 body - executable file extension not allowed."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MimeRejected",
    type: :object,
    properties: %{
      error: %Schema{type: :string, example: "extension_not_allowed"},
      extension: %Schema{type: :string, example: ".exe"}
    },
    required: [:error, :extension]
  })
end

defmodule EngramWeb.Schemas.BatchItemError do
  @moduledoc "Batch op error pinpointing the offending item path."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BatchItemError",
    type: :object,
    properties: %{
      error: %Schema{type: :string, example: "conflict"},
      item_path: %Schema{type: :string}
    },
    required: [:error]
  })
end

defmodule EngramWeb.Schemas.AttachmentUploadStartRequest do
  @moduledoc "Opens a chunked attachment upload."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentUploadStartRequest",
    type: :object,
    properties: %{
      path: %Schema{type: :string, example: "videos/clip.mp4"},
      size_bytes: %Schema{type: :integer, minimum: 1, description: "Total file size."},
      mtime: %Schema{type: :number, format: :float, nullable: true},
      mime_type: %Schema{
        type: :string,
        nullable: true,
        description: "Detected from path if omitted."
      }
    },
    required: [:path, :size_bytes]
  })
end

defmodule EngramWeb.Schemas.AttachmentUploadSession do
  @moduledoc "A started chunked upload: send `part_count` parts of `part_size` bytes."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentUploadSession",
    type: :object,
    properties: %{
      upload_id: %Schema{type: :string, format: :uuid},
      part_size: %Schema{type: :integer, example: 8_388_608},
      part_count: %Schema{type: :integer}
    },
    required: [:upload_id, :part_size, :part_count]
  })
end

defmodule EngramWeb.Schemas.AttachmentUploadPart do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentUploadPart",
    type: :object,
    properties: %{part: %Schema{type: :integer}},
    required: [:part]
  })
end

defmodule EngramWeb.Schemas.AttachmentUploadStatus do
  @moduledoc "Which parts of a chunked upload the server holds."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentUploadStatus",
    type: :object,
    properties: %{
      done: %Schema{type: :array, items: %Schema{type: :integer}},
      part_count: %Schema{type: :integer},
      part_size: %Schema{type: :integer}
    },
    required: [:done, :part_count, :part_size]
  })
end

defmodule EngramWeb.Schemas.AttachmentUploadMissingParts do
  @moduledoc "409 body - complete called before every part was stored."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttachmentUploadMissingParts",
    type: :object,
    properties: %{
      error: %Schema{type: :string, example: "missing_parts"},
      missing: %Schema{type: :array, items: %Schema{type: :integer}}
    },
    required: [:error, :missing]
  })
end
