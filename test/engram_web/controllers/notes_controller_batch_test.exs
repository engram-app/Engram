defmodule EngramWeb.NotesControllerBatchTest do
  use EngramWeb.ConnCase, async: true

  setup :authed_api_conn

  describe "POST /api/notes/batch-delete" do
    test "atomic delete + idempotency replay", %{conn: conn, user: user, vault: vault} do
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "a.md"}, actor: "api")
      {:ok, n2} = Engram.Notes.upsert_note(user, vault, %{path: "b.md"}, actor: "api")
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
      {:ok, n} = Engram.Notes.upsert_note(user, vault, %{path: "x.md"}, actor: "api")
      conn |> post(~p"/api/notes/batch-delete", %{ids: [n.id]}) |> json_response(400)
    end

    test "404 in batch rolls back all", %{conn: conn, user: user, vault: vault} do
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "a.md"}, actor: "api")
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

  describe "POST /api/notes/batch-delete client contract" do
    test "501 ids is a 422 naming the cap; nothing is deleted", ctx do
      %{conn: conn, user: user, vault: vault} = ctx
      {:ok, n} = Engram.Notes.upsert_note(user, vault, %{path: "keep.md"}, actor: "api")
      ids = [n.id | for(_ <- 1..500, do: Ecto.UUID.generate())]

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-delete", %{ids: ids})
        |> json_response(422)

      assert body == %{"error" => "batch_too_large", "max" => 500}
      assert {:ok, _} = Engram.Notes.get_note_by_id(user, vault, n.id)
    end

    test "an already-deleted id is a no-op, not a 404 for the batch", ctx do
      %{conn: conn, user: user, vault: vault} = ctx
      {:ok, gone} = Engram.Notes.upsert_note(user, vault, %{path: "gone.md"}, actor: "api")
      {:ok, live} = Engram.Notes.upsert_note(user, vault, %{path: "live.md"}, actor: "api")
      assert {:ok, %{deleted: 1}} = Engram.Notes.batch_delete_notes(user, vault, [gone.id])
      assert {:error, :not_found} = Engram.Notes.get_note_by_id(user, vault, gone.id)

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-delete", %{ids: [gone.id, live.id]})
        |> json_response(200)

      assert body == %{"deleted" => 1}
      assert {:error, :not_found} = Engram.Notes.get_note_by_id(user, vault, live.id)
    end

    test "tags each delete echo with the caller's X-Device-Id", ctx do
      %{conn: conn, user: user, vault: vault} = ctx
      {:ok, n} = Engram.Notes.upsert_note(user, vault, %{path: "echo.md"}, actor: "api")
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      conn
      |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
      |> put_req_header("x-device-id", "device-a")
      |> post(~p"/api/notes/batch-delete", %{ids: [n.id]})
      |> json_response(200)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "device_id" => "device-a"}
      }
    end
  end

  describe "POST /api/notes/batch-move" do
    test "501 ids is a 422; nothing moves", %{conn: conn, user: user, vault: vault} do
      {:ok, n} = Engram.Notes.upsert_note(user, vault, %{path: "stay.md"}, actor: "api")
      ids = [n.id | for(_ <- 1..500, do: Ecto.UUID.generate())]

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-move", %{ids: ids, target_folder: "Elsewhere"})
        |> json_response(422)

      assert body["error"] == "batch_too_large"
      assert {:ok, %{path: "stay.md"}} = Engram.Notes.get_note_by_id(user, vault, n.id)
    end

    test "atomic move + idempotency replay", %{conn: conn, user: user, vault: vault} do
      {:ok, target} = Engram.Notes.create_folder_marker(user, vault, "Archive")
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "a.md"}, actor: "api")
      {:ok, n2} = Engram.Notes.upsert_note(user, vault, %{path: "b.md"}, actor: "api")

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-move", %{ids: [n1.id, n2.id], target_folder_id: target.id})
        |> json_response(200)

      assert body == %{"moved" => 2}
    end

    test "409 on collision", %{conn: conn, user: user, vault: vault} do
      {:ok, target} = Engram.Notes.create_folder_marker(user, vault, "Archive")
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "a.md"}, actor: "api")

      {:ok, _conflict} =
        Engram.Notes.upsert_note(user, vault, %{path: "Archive/a.md"}, actor: "api")

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
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "Archive/a.md"}, actor: "api")

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-move", %{ids: [n1.id], target_folder_id: "root"})
        |> json_response(200)

      assert body == %{"moved" => 1}
      {:ok, moved} = Engram.Notes.get_note_by_id(user, vault, n1.id)
      assert moved.path == "a.md"
    end

    test "moves notes into a derived folder via target_folder path (no marker)", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, n1} = Engram.Notes.upsert_note(user, vault, %{path: "a.md"}, actor: "api")

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch-move", %{ids: [n1.id], target_folder: "Derived/Sub"})
        |> json_response(200)

      assert body == %{"moved" => 1}
      {:ok, moved} = Engram.Notes.get_note_by_id(user, vault, n1.id)
      assert moved.path == "Derived/Sub/a.md"
    end
  end
end

defmodule EngramWeb.NotesControllerBatchRateTest do
  # The handshake budget override is global app env.
  use EngramWeb.ConnCase, async: false

  setup :authed_api_conn

  setup do
    Application.put_env(:engram, :crdt_hs_rate_limit_override, 2)
    on_exit(fn -> Application.delete_env(:engram, :crdt_hs_rate_limit_override) end)
  end

  test "batch delete spends the socket's per-device delete budget, one unit per id", ctx do
    %{conn: conn, user: user, vault: vault} = ctx
    device = "rate-#{System.unique_integer([:positive])}"

    notes =
      for i <- 1..3 do
        {:ok, n} = Engram.Notes.upsert_note(user, vault, %{path: "r#{i}.md"}, actor: "api")
        n
      end

    post_delete = fn ids ->
      conn
      |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
      |> put_req_header("x-device-id", device)
      |> post(~p"/api/notes/batch-delete", %{ids: ids})
    end

    assert json_response(post_delete.(Enum.map(Enum.take(notes, 2), & &1.id)), 200)

    last = List.last(notes)
    assert %{"error" => "rate_limited"} = json_response(post_delete.([last.id]), 429)
    assert {:ok, _} = Engram.Notes.get_note_by_id(user, vault, last.id)
  end
end
