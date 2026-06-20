defmodule EngramWeb.TagsController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Notes

  operation(:index,
    operation_id: "tags",
    summary: "List all tags in the vault",
    description: "Returns the distinct set of tags used across all notes in the current vault.",
    tags: ["Tags"],
    responses: [ok: {"Tags", "application/json", Schemas.TagsResponse}]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, tags} = Notes.list_tags(user, vault)
    json(conn, %{tags: Enum.map(tags, &%{name: &1})})
  end
end
