defmodule EngramWeb.Schemas.LogInput do
  @moduledoc "A single client log line submitted for remote ingestion."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LogInput",
    type: :object,
    properties: %{
      level: %Schema{type: :string, example: "error"},
      category: %Schema{type: :string, nullable: true},
      message: %Schema{type: :string},
      stack: %Schema{type: :string, nullable: true},
      ts: %Schema{type: :string, format: :"date-time", nullable: true},
      plugin_version: %Schema{type: :string, nullable: true},
      platform: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule EngramWeb.Schemas.LogIngestRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LogIngestRequest",
    type: :object,
    properties: %{logs: %Schema{type: :array, items: EngramWeb.Schemas.LogInput}},
    required: [:logs]
  })
end

defmodule EngramWeb.Schemas.LogIngestResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LogIngestResponse",
    type: :object,
    properties: %{
      ok: %Schema{type: :boolean, example: true},
      count: %Schema{type: :integer, description: "Number of log lines persisted."}
    },
    required: [:ok, :count]
  })
end

defmodule EngramWeb.Schemas.LogRecord do
  @moduledoc "A persisted remote log line."
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LogRecord",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      ts: %Schema{type: :string, format: :"date-time", nullable: true},
      level: %Schema{type: :string, nullable: true},
      category: %Schema{type: :string, nullable: true},
      message: %Schema{type: :string, nullable: true},
      stack: %Schema{type: :string, nullable: true},
      plugin_version: %Schema{type: :string, nullable: true},
      platform: %Schema{type: :string, nullable: true},
      created_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end

defmodule EngramWeb.Schemas.LogsResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LogsResponse",
    type: :object,
    properties: %{logs: %Schema{type: :array, items: EngramWeb.Schemas.LogRecord}},
    required: [:logs]
  })
end
