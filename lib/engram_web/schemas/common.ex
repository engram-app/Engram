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
      },
      links: %Schema{
        type: :array,
        items: EngramWeb.Schemas.NoteLink,
        description: "Outgoing link/embed edges, resolved. Wikilink and markdown syntax alike."
      }
    },
    required: [:path]
  })
end

defmodule EngramWeb.Schemas.NoteLink do
  @moduledoc "A resolved outgoing link/embed edge from a note (wikilink or markdown syntax)."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "NoteLink",
    type: :object,
    properties: %{
      target_text: %Schema{
        type: :string,
        description:
          "The link target, percent-DECODED. `[[Target]]` and `[x](Target.md)` " <>
            "both yield `Target`/`Target.md` here — not the literal source bytes."
      },
      target_note_id: %Schema{type: :string, format: :uuid, nullable: true},
      target_attachment_id: %Schema{type: :string, format: :uuid, nullable: true},
      target_path: %Schema{type: :string, nullable: true, description: "Resolved note path."},
      alias: %Schema{
        type: :string,
        nullable: true,
        description: "Display text: `[[target|alias]]`'s alias, or `[label](target)`'s label."
      },
      anchor: %Schema{
        type: :string,
        nullable: true,
        description: "Heading/block reference: `[[target#anchor]]` or `[x](target#anchor)`."
      },
      link_type: %Schema{
        type: :string,
        description:
          ~s|"wikilink" or "embed" — whether the link EMBEDS its target. | <>
            ~s|Not the source syntax; markdown-form links carry these same two values.|
      },
      dangling: %Schema{
        type: :boolean,
        description: "True when the target could not be resolved."
      }
    },
    required: [:target_text, :link_type, :dangling]
  })
end

defmodule EngramWeb.Schemas.Backlink do
  @moduledoc "A resolved incoming edge (backlink) from another note."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Backlink",
    type: :object,
    properties: %{
      source_note_id: %Schema{type: :string, format: :uuid},
      source_path: %Schema{type: :string, nullable: true},
      source_title: %Schema{type: :string, nullable: true},
      alias: %Schema{type: :string, nullable: true},
      anchor: %Schema{type: :string, nullable: true}
    },
    required: [:source_note_id]
  })
end

defmodule EngramWeb.Schemas.Backlinks do
  @moduledoc "Inverse links (backlinks) pointing at a note."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Backlinks",
    type: :object,
    properties: %{
      backlinks: %Schema{
        type: :array,
        items: EngramWeb.Schemas.Backlink,
        description: "Capped at 200 edges, ordered oldest-first. Not paginated yet."
      }
    },
    required: [:backlinks]
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
