defmodule EngramWeb.NotesControllerBatchTest do
  use EngramWeb.ConnCase, async: true

  setup :authed_api_conn

  describe "POST /api/notes/batch-delete" do
    test "atomic delete + idempotency replay", %{conn: conn, user: user, vault: vault} do
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "a.md"})
      {:ok, n2} = Engram.Notes.upsert_note(user, vault, %{path: "b.md"})
      key = Ecto.UUID.generate()

      body =
        conn
        |> put_req_header("x-idempotency-key", key)
        |> post(~p"/api/notes/batch-delete", %{ids: [n1.id, n2.id]})
        |> json_response(200)

      assert body == %{"deleted" => 2}

      replay =
        conn
        |> put_req_header("x-idempotency-key", key)
        |> post(~p"/api/notes/batch-delete", %{ids: [n1.id, n2.id]})
        |> json_response(200)

      assert replay == body
    end

    test "missing idempotency key → 400", %{conn: conn, user: user, vault: vault} do
      {:ok, n} = Engram.Notes.upsert_note(user, vault, %{path: "x.md"})
      conn |> post(~p"/api/notes/batch-delete", %{ids: [n.id]}) |> json_response(400)
    end

    test "404 in batch rolls back all", %{conn: conn, user: user, vault: vault} do
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "a.md"})
      missing_id = Ecto.UUID.generate()

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-delete", %{ids: [n1.id, missing_id]})
        |> json_response(404)

      assert body["error"] == "not_found"
      assert body["item_id"] == missing_id
      assert {:ok, _} = Engram.Notes.get_note_by_id(user, vault, n1.id)
    end
  end

  describe "POST /api/notes/batch-move" do
    test "atomic move + idempotency replay", %{conn: conn, user: user, vault: vault} do
      {:ok, target} = Engram.Notes.create_folder_marker(user, vault, "Archive")
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "a.md"})
      {:ok, n2} = Engram.Notes.upsert_note(user, vault, %{path: "b.md"})

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-move", %{ids: [n1.id, n2.id], target_folder_id: target.id})
        |> json_response(200)

      assert body == %{"moved" => 2}
    end

    test "409 on collision", %{conn: conn, user: user, vault: vault} do
      {:ok, target} = Engram.Notes.create_folder_marker(user, vault, "Archive")
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "a.md"})
      {:ok, _conflict} = Engram.Notes.upsert_note(user, vault, %{path: "Archive/a.md"})

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-move", %{ids: [n1.id], target_folder_id: target.id})
        |> json_response(409)

      assert body["error"] == "conflict"
      assert body["item_id"] == n1.id
    end

    test "moves notes to the vault root via target_folder_id \"root\"", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _marker} = Engram.Notes.create_folder_marker(user, vault, "Archive")
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "Archive/a.md"})

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-move", %{ids: [n1.id], target_folder_id: "root"})
        |> json_response(200)

      assert body == %{"moved" => 1}
      {:ok, moved} = Engram.Notes.get_note_by_id(user, vault, n1.id)
      assert moved.path == "a.md"
    end
  end
end
