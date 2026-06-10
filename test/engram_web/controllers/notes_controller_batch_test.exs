defmodule EngramWeb.NotesControllerBatchTest do
  use EngramWeb.ConnCase, async: false

  setup %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
  end

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

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-delete", %{ids: [n1.id, Ecto.UUID.generate()]})
        |> json_response(404)

      assert body["error"] == "not_found"
      assert body["item_id"] == 999_999
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
  end
end
