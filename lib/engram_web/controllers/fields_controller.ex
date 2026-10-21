defmodule EngramWeb.FieldsController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Notes.FieldCatalog

  operation(:index,
    operation_id: "fields",
    summary: "List every frontmatter field in the vault",
    description:
      "Returns every frontmatter field the vault's indexed notes use: its name (the `key` " <>
        "of a search `fields` filter), value kinds, how many live notes carry it, whether " <>
        "a note holds a list of values, the number or date range, and the 50 most used " <>
        "exact values with note counts. Most used fields first. Derived from the index, " <>
        "so a note's fields appear once it has been indexed. `filterable` says whether " <>
        "search accepts `fields` filters on this server yet.",
    tags: ["Fields"],
    responses: [ok: {"Fields", "application/json", Schemas.FieldsResponse}]
  )

  def index(conn, _params) do
    {:ok, fields} = FieldCatalog.list(conn.assigns.current_user, conn.assigns.current_vault)
    json(conn, %{fields: fields, filterable: Engram.Search.FieldFilters.available?()})
  end
end
