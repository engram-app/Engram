defmodule EngramWeb.NotesControllerBatchUpsertTest do
  use EngramWeb.ConnCase, async: false

  setup %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
  end

  describe "POST /api/notes/batch" do
    test "bulk insert returns per-note results + idempotency replay", %{conn: conn} do
      key = Ecto.UUID.generate()

      notes = [
        %{path: "a.md", content: "# A", mtime: 1.0},
        %{path: "sub/b.md", content: "# B", mtime: 2.0}
      ]

      body =
        conn
        |> put_req_header("x-idempotency-key", key)
        |> post(~p"/api/notes/batch", %{notes: notes})
        |> json_response(200)

      assert [r1, r2] = body["results"]
      assert %{"path" => "a.md", "status" => "ok", "version" => 1} = r1
      assert is_binary(r1["id"])
      assert is_binary(r1["content_hash"])
      assert %{"path" => "sub/b.md", "status" => "ok"} = r2

      replay =
        conn
        |> put_req_header("x-idempotency-key", key)
        |> post(~p"/api/notes/batch", %{notes: notes})
        |> json_response(200)

      assert replay == body
    end

    test "missing idempotency key → 400", %{conn: conn} do
      conn
      |> post(~p"/api/notes/batch", %{notes: [%{path: "a.md", content: "x", mtime: 1.0}]})
      |> json_response(400)
    end

    test "more than 100 notes → 400", %{conn: conn} do
      notes = for i <- 1..101, do: %{path: "n#{i}.md", content: "x", mtime: 1.0}

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch", %{notes: notes})
        |> json_response(400)

      assert body["error"] == "too_many_notes"
      assert body["max"] == 100
    end

    test "missing notes param → 400", %{conn: conn} do
      conn
      |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
      |> post(~p"/api/notes/batch", %{})
      |> json_response(400)
    end

    test "oversized note becomes a per-note error without failing the batch", %{conn: conn} do
      big = String.duplicate("a", 10 * 1024 * 1024 + 1)

      notes = [
        %{path: "big.md", content: big, mtime: 1.0},
        %{path: "ok.md", content: "fine", mtime: 1.0}
      ]

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch", %{notes: notes})
        |> json_response(200)

      assert [big_result, ok_result] = body["results"]
      assert %{"path" => "big.md", "status" => "error"} = big_result
      assert %{"path" => "ok.md", "status" => "ok"} = ok_result
    end

    test "stale version yields a conflict entry mirroring the single-note 409 body", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{path: "a.md", content: "v1", mtime: 1.0})

      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{path: "a.md", content: "v2", mtime: 2.0})

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch", %{
          notes: [%{path: "a.md", content: "mine", mtime: 3.0, version: 1}]
        })
        |> json_response(200)

      assert [%{"path" => "a.md", "status" => "conflict", "server_note" => server_note}] =
               body["results"]

      assert server_note["content"] == "v2"
      assert server_note["version"] == 2
      assert server_note["path"] == "a.md"
      assert is_binary(server_note["content_hash"])
    end

    test "cap exceeded → 402 with LimitResponse shape, nothing committed", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 1})

      body =
        conn
        |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
        |> post(~p"/api/notes/batch", %{
          notes: [
            %{path: "a.md", content: "x", mtime: 1.0},
            %{path: "b.md", content: "x", mtime: 1.0}
          ]
        })
        |> json_response(402)

      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "notes_cap_exceeded"
      assert body["limit"] == 1

      assert {:error, :not_found} = Engram.Notes.get_note(user, vault, "a.md")
    end
  end
end
