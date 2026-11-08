defmodule Engram.Folders.LargeFolderOpTest do
  # A folder rename or batch move has no size limit: one of 201 items (one
  # past the removed 200-row cap) runs on every surface.
  use EngramWeb.ConnCase, async: true

  alias Engram.{Fixtures, Folders, Notes}
  alias Engram.MCP.Handlers

  setup :authed_api_conn

  # The folder walk is keyed by the user's DEK; without one it finds nothing.
  setup %{user: user} do
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    %{user: user}
  end

  @items 201

  test "Folders.rename of a folder with 201 items succeeds", %{user: u, vault: v} do
    :ok = Fixtures.fill_folder!(u, v, "A", @items, 0)
    assert {:ok, %{notes: 196}} = Folders.rename(u, v, "A", "B")
  end

  test "Folders.batch_move of folders with 201 items in total succeeds", %{user: u, vault: v} do
    {:ok, %{folders: [a, b, _dst]}} = Notes.create_folder_markers(u, v, ["A", "B", "Dst"])
    :ok = Fixtures.fill_folder!(u, v, "A", 100, 0)
    :ok = Fixtures.fill_folder!(u, v, "B", 101, 0)

    assert {:ok, _} = Folders.batch_move(u, v, [a.id, b.id], {:path, "Dst"})
  end

  test "MCP rename_folder of a folder with 201 items succeeds", %{user: u, vault: v} do
    :ok = Fixtures.fill_folder!(u, v, "A", @items, 0)

    assert {:ok, "Folder renamed: A -> B (196 notes" <> _, _} =
             Handlers.handle("rename_folder", u, v, %{"old_folder" => "A", "new_folder" => "B"})
  end

  test "POST /api/folders/rename of a folder with 201 items is a 200", %{
    conn: conn,
    user: u,
    vault: v
  } do
    :ok = Fixtures.fill_folder!(u, v, "A", @items, 0)

    conn
    |> post(~p"/api/folders/rename", %{"old_path" => "A", "new_path" => "B"})
    |> json_response(200)
  end

  test "POST /api/folders/batch-move of a folder with 201 items is a 200", %{
    conn: conn,
    user: u,
    vault: v
  } do
    {:ok, a} = Notes.create_folder_marker(u, v, "A")
    :ok = Fixtures.fill_folder!(u, v, "A", @items, 0)

    conn
    |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
    |> post(~p"/api/folders/batch-move", %{"ids" => [a.id], "target_parent" => "Dst"})
    |> json_response(200)
  end
end
