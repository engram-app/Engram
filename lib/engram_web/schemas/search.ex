defmodule EngramWeb.Schemas.SearchRequest do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex
  OpenApiSpex.schema(%{
    title: "SearchRequest",
    type: :object,
    properties: %{
      query: %Schema{type: :string},
      limit: %Schema{type: :integer, description: "1..50, default 5"},
      tags: %Schema{type: :array, items: %Schema{type: :string}},
      folder: %Schema{type: :string},
      mode: %Schema{type: :string, enum: ["keyword", "vector", "hybrid"]},
      cross_vault: %Schema{type: :boolean, description: "Pro plan only."}
    },
    required: [:query]
  })
end

defmodule EngramWeb.Schemas.SearchResult do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex
  OpenApiSpex.schema(%{
    title: "SearchResult",
    type: :object,
    properties: %{
      id: %Schema{type: :string, format: :uuid, nullable: true},
      path: %Schema{type: :string},
      title: %Schema{type: :string, nullable: true},
      folder: %Schema{type: :string, nullable: true},
      heading_path: %Schema{type: :string, nullable: true},
      snippet: %Schema{type: :string},
      score: %Schema{type: :number, format: :float},
      match_count: %Schema{type: :integer}
    }
  })
end

defmodule EngramWeb.Schemas.SearchResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex
  OpenApiSpex.schema(%{
    title: "SearchResponse",
    type: :object,
    properties: %{results: %Schema{type: :array, items: EngramWeb.Schemas.SearchResult}},
    required: [:results]
  })
end

defmodule EngramWeb.Schemas.TagsResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex
  OpenApiSpex.schema(%{
    title: "TagsResponse",
    type: :object,
    properties: %{
      tags: %Schema{
        type: :array,
        items: %Schema{type: :object, properties: %{name: %Schema{type: :string}}}
      }
    },
    required: [:tags]
  })
end
