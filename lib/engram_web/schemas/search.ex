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
      type: %Schema{
        type: :string,
        description:
          "Filter to notes whose frontmatter `type` equals this value (case-insensitive)."
      },
      created_after: %Schema{
        type: :string,
        format: :"date-time",
        description:
          "Only notes whose frontmatter created date is at or after this ISO 8601 instant."
      },
      created_before: %Schema{
        type: :string,
        format: :"date-time",
        description:
          "Only notes whose frontmatter created date is at or before this ISO 8601 instant."
      },
      updated_after: %Schema{
        type: :string,
        format: :"date-time",
        description:
          "Only notes whose frontmatter timestamp is at or after this ISO 8601 instant."
      },
      updated_before: %Schema{
        type: :string,
        format: :"date-time",
        description:
          "Only notes whose frontmatter timestamp is at or before this ISO 8601 instant."
      },
      mode: %Schema{type: :string, enum: ["keyword", "vector", "hybrid"]},
      cross_vault: %Schema{type: :boolean, description: "Pro plan only."},
      diversity: %Schema{
        type: :number,
        minimum: 0.0,
        maximum: 1.0,
        description:
          "Result diversity (MMR). 0 = most relevant (default, tuned per plan); 1 = most varied."
      }
    },
    required: [:query],
    example: %{
      "query" => "omega-3 dosage",
      "limit" => 5,
      "type" => "Playbook",
      "mode" => "hybrid",
      "diversity" => 0.3
    }
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

defmodule EngramWeb.Schemas.TypesResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TypesResponse",
    type: :object,
    properties: %{
      types: %Schema{
        type: :array,
        items: %Schema{type: :object, properties: %{name: %Schema{type: :string}}}
      }
    },
    required: [:types]
  })
end

defmodule EngramWeb.Schemas.FieldsResponse do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  range = fn type, description ->
    %Schema{
      type: :object,
      nullable: true,
      description: description,
      properties: %{min: %Schema{type: type}, max: %Schema{type: type}},
      required: [:min, :max]
    }
  end

  OpenApiSpex.schema(%{
    title: "FieldsResponse",
    type: :object,
    properties: %{
      fields: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "The key a search `fields` filter takes"},
            kinds: %Schema{
              type: :array,
              items: %Schema{type: :string, enum: ~w(string boolean number date)}
            },
            list: %Schema{type: :boolean, description: "Some note holds several values"},
            note_count: %Schema{type: :integer, description: "Live notes carrying the field"},
            number_range: range.(:number, "Smallest and largest number, or null"),
            date_range:
              range.(:string, "Earliest and latest ISO date or datetime (UTC), or null"),
            values: %Schema{
              type: :array,
              description: "Most used exact values (at most 50), most notes first",
              items: %Schema{
                type: :object,
                properties: %{value: %Schema{type: :string}, count: %Schema{type: :integer}},
                required: [:value, :count]
              }
            }
          },
          required: [:name, :kinds, :list, :note_count, :number_range, :date_range, :values]
        }
      }
    },
    required: [:fields],
    example: %{
      "fields" => [
        %{
          "name" => "status",
          "kinds" => ["string"],
          "list" => false,
          "note_count" => 42,
          "number_range" => nil,
          "date_range" => nil,
          "values" => [%{"value" => "draft", "count" => 30}, %{"value" => "done", "count" => 12}]
        },
        %{
          "name" => "priority",
          "kinds" => ["number"],
          "list" => false,
          "note_count" => 17,
          "number_range" => %{"min" => 1.0, "max" => 5.0},
          "date_range" => nil,
          "values" => []
        },
        %{
          "name" => "due",
          "kinds" => ["date"],
          "list" => false,
          "note_count" => 9,
          "number_range" => nil,
          "date_range" => %{"min" => "2026-09-01", "max" => "2026-12-15"},
          "values" => []
        }
      ]
    }
  })
end
