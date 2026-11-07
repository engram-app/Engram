defmodule EngramWeb.FoldersOpSizeCapTest do
  # #2492: an over-cap folder rename or move is a 422 with the count.
  # async: false, since the cap is lowered globally.
  use EngramWeb.ConnCase, async: false

  alias Engram.Notes

  setup :authed_api_conn

  setup do
    cap = Application.get_env(:engram, :folder_op_max_rows)
    Application.put_env(:engram, :folder_op_max_rows, 1)
    on_exit(fn -> Application.put_env(:engram, :folder_op_max_rows, cap) end)
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

    assert body == %{"error" => "folder_too_large", "count" => 2, "limit" => 1}
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

    assert body == %{"error" => "folder_too_large", "count" => 2, "limit" => 1}
  end
end
