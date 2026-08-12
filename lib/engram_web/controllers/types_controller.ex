defmodule EngramWeb.TypesController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Notes

  operation(:index,
    operation_id: "types",
    summary: "List all OKF types in the vault",
    description:
      "Returns the distinct set of Open Knowledge Format `type` values used across all " <>
        "notes in the current vault, normalised (NFKC + lowercase) to match how the " <>
        "search filter buckets them.",
    tags: ["Types"],
    responses: [ok: {"Types", "application/json", Schemas.TypesResponse}]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    {:ok, types} = Notes.list_types(user, vault)
    json(conn, %{types: Enum.map(types, &%{name: &1})})
  end
end
