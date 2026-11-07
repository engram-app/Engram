defmodule EngramWeb.FoldersOpSizeCapTest do
  # #2492: an over-cap folder rename or move is a 422 with the count.
  use EngramWeb.ConnCase, async: true

  alias Engram.Notes

  setup :authed_api_conn

  setup do
    Engram.ServiceConfig.put_override(:folder_op_max_rows, 1)
  end

  defp put_note(user, vault, path) do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")
  end

  test "POST /api/folders/rename over the cap is a 422 with count and limit", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    put_note(user, vault, "A/x.md")
    put_note(user, vault, "A/y.md")

    body =
      conn
      |> post(~p"/api/folders/rename", %{"old_path" => "A", "new_path" => "B"})
      |> json_response(422)

    assert body == %{"error" => "folder_too_large", "limit" => 1, "over_limit" => true}
  end

  test "POST /api/folders/batch-move over the cap is a 422 with count and limit", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    {:ok, a} = Notes.create_folder_marker(user, vault, "A")
    put_note(user, vault, "A/x.md")
    put_note(user, vault, "A/y.md")

    body =
      conn
      |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
      |> post(~p"/api/folders/batch-move", %{"ids" => [a.id], "target_parent" => "Dst"})
      |> json_response(422)

    assert body == %{"error" => "folder_too_large", "limit" => 1, "over_limit" => true}
  end
end
