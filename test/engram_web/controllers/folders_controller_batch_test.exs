defmodule EngramWeb.FoldersControllerBatchTest do
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
  end

  describe "POST /api/folders/batch-delete" do
    test "atomic cascading delete + idempotency replay", %{conn: conn, user: user, vault: vault} do
      {:ok, marker} = Engram.Notes.create_folder_marker(user, vault, "Projects")
      {:ok, child} = Engram.Notes.upsert_note(user, vault, %{path: "Projects/a.md"})
      key = Ecto.UUID.generate()

      body =
        conn
        |> put_req_header("x-idempotency-key", key)
        |> post(~p"/api/folders/batch-delete", %{ids: [marker.id]})
        |> json_response(200)

      # batch_delete_folders returns the SUM of cascade counts (marker + descendants).
      # See Engram.Notes.batch_delete_folders/3 docstring: 1 marker + 1 child note = 2.
      assert body == %{"deleted" => 2}
      # delete_folder/3 cascades — child note also gone.
      assert {:error, :not_found} = Engram.Notes.get_note_by_id(user, vault, child.id)

      # Replay
      replay =
        conn
        |> put_req_header("x-idempotency-key", key)
        |> post(~p"/api/folders/batch-delete", %{ids: [marker.id]})
        |> json_response(200)

      assert replay == body
    end

    test "missing idempotency key → 400", %{conn: conn, user: user, vault: vault} do
      {:ok, marker} = Engram.Notes.create_folder_marker(user, vault, "X")
      conn |> post(~p"/api/folders/batch-delete", %{ids: [marker.id]}) |> json_response(400)
    end

    test "404 on missing id rolls back all", %{conn: conn, user: user, vault: vault} do
      {:ok, marker} = Engram.Notes.create_folder_marker(user, vault, "X")
      {:ok, _child} = Engram.Notes.upsert_note(user, vault, %{path: "X/a.md"})
      missing_id = Ecto.UUID.generate()

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/folders/batch-delete", %{ids: [marker.id, missing_id]})
        |> json_response(404)

      assert body["error"] == "not_found"
      assert body["item_id"] == missing_id
    end
  end

  describe "POST /api/folders/batch-move" do
    test "atomic move + idempotency replay", %{conn: conn, user: user, vault: vault} do
      {:ok, src} = Engram.Notes.create_folder_marker(user, vault, "Projects")
      {:ok, dst} = Engram.Notes.create_folder_marker(user, vault, "Archive")
      {:ok, child} = Engram.Notes.upsert_note(user, vault, %{path: "Projects/a.md"})

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/folders/batch-move", %{ids: [src.id], target_parent_id: dst.id})
        |> json_response(200)

      assert body == %{"moved" => 1}
      {:ok, after_move} = Engram.Notes.get_note_by_id(user, vault, child.id)
      assert after_move.path == "Archive/Projects/a.md"
    end

    test "409 on cycle (move folder into its own descendant)", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, parent} = Engram.Notes.create_folder_marker(user, vault, "a")
      {:ok, child} = Engram.Notes.create_folder_marker(user, vault, "a/b")

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/folders/batch-move", %{ids: [parent.id], target_parent_id: child.id})
        |> json_response(409)

      # The batch_move_folders error contract returns {:error, {:cycle, id}}.
      assert body["error"] == "cycle"
      assert body["item_id"] == parent.id
    end

    test "moves a nested folder to the vault root via target_parent_id \"root\"", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _parent} = Engram.Notes.create_folder_marker(user, vault, "a")
      {:ok, child} = Engram.Notes.create_folder_marker(user, vault, "a/b")
      {:ok, note} = Engram.Notes.upsert_note(user, vault, %{path: "a/b/x.md"})

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/folders/batch-move", %{ids: [child.id], target_parent_id: "root"})
        |> json_response(200)

      assert body == %{"moved" => 1}
      {:ok, moved} = Engram.Notes.get_note_by_id(user, vault, note.id)
      assert moved.path == "b/x.md"
    end
  end
end
