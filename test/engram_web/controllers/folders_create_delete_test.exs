defmodule EngramWeb.FoldersCreateDeleteTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.Notes
  alias Engram.Repo

  setup %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
  end

  describe "POST /folders" do
    test "creates a marker and returns 201", %{conn: conn} do
      conn = post(conn, "/api/folders", %{"folder" => "Projects/Active"})
      body = json_response(conn, 201)
      assert body["folder"]["name"] == "Projects/Active"
      assert body["folder"]["count"] == 0
    end

    test "idempotent on existing marker", %{conn: conn} do
      _ = post(conn, "/api/folders", %{"folder" => "Twice"})
      conn = post(conn, "/api/folders", %{"folder" => "Twice"})
      assert conn.status in [200, 201]
    end

    test "broadcasts folders.batch create on the sync channel", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      post(conn, "/api/folders", %{"folder" => "Live/New"})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "folders.batch",
        payload: %{op: "create", folder: "Live/New"}
      }
    end

    test "the create broadcast names the marker's id", %{conn: conn, user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      post(conn, "/api/folders", %{"folder" => "Live/New"})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "folders.batch",
        payload: %{op: "create", markers: [%{id: id, name: "Live/New"}]}
      }

      tree = json_response(get(conn, "/api/vault/tree"), 200)
      assert %{"id" => ^id} = Enum.find(tree["folders"], &(&1["name"] == "Live/New"))
    end

    # #2161: a re-create of a live folder changes nothing, so like the batch
    # endpoint it must not make every peer re-poll /folders/explicit (a loop
    # of those re-polls is the suspected POST storm amplifier).
    test "idempotent re-create sends no broadcast, a new folder still does", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      _ = post(conn, "/api/folders", %{"folder" => "Twice"})
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      assert conn |> post("/api/folders", %{"folder" => "Twice"}) |> json_response(201)
      refute_receive %Phoenix.Socket.Broadcast{event: "folders.batch"}, 100

      post(conn, "/api/folders", %{"folder" => "Fresh"})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "folders.batch",
        payload: %{op: "create", folder: "Fresh"}
      }
    end

    test "undeleting through the single route broadcasts the original id", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      post(conn, "/api/folders", %{"folder" => "Back"})
      assert_receive %Phoenix.Socket.Broadcast{payload: %{markers: [%{id: id}]}}
      {:ok, :deleted} = Notes.delete_folder_marker(Repo.reload!(user), vault, "Back")

      assert conn |> post("/api/folders", %{"folder" => "Back"}) |> json_response(201)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "folders.batch",
        payload: %{op: "create", markers: [%{id: ^id, name: "Back"}]}
      }
    end

    # #2121 through the REST route: a name holding only tombstones revives the
    # most recently deleted one, whatever order Postgres returns the rows in.
    test "with two tombstones, re-create revives the newest", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      post(conn, "/api/folders", %{"folder" => "GateG"})
      assert_receive %Phoenix.Socket.Broadcast{payload: %{markers: [%{id: orig}]}}
      user = Repo.reload!(user)
      {:ok, :deleted} = Notes.delete_folder_marker(user, vault, "GateG")
      post(conn, "/api/folders", %{"folder" => "GateF"})
      assert_receive %Phoenix.Socket.Broadcast{payload: %{markers: [%{id: moved}]}}
      {:ok, _} = Notes.rename_folder(user, vault, "GateF", "GateG")
      {:ok, :deleted} = Notes.delete_folder_marker(user, vault, "GateG")

      # The moved row was written last, so heap order returns it last. Make it
      # the OLDER tombstone, so the right answer is the row Postgres returns first.
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          {:ok, orig_uuid} = Ecto.UUID.dump(orig)
          {:ok, moved_uuid} = Ecto.UUID.dump(moved)

          Repo.query!(
            "UPDATE notes SET deleted_at = (SELECT deleted_at FROM notes WHERE id = $1) - interval '1 hour' WHERE id = $2",
            [orig_uuid, moved_uuid]
          )
        end)

      assert conn |> post("/api/folders", %{"folder" => "GateG"}) |> json_response(201)

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{op: "create", markers: [%{id: ^orig, name: "GateG"}]}
      }
    end

    test "rejects empty folder with 422", %{conn: conn} do
      conn = post(conn, "/api/folders", %{"folder" => ""})
      body = json_response(conn, 422)
      assert body["error"] =~ "folder"
    end

    # Same PathSanitizer rules notes get: traversal, absolute, null-byte and
    # percent-encoded dot segments are rewritten, never stored as given.
    for {input, expected} <- [
          {"../x", "x"},
          {"/abs", "abs"},
          {"a/../../b", "a/b"},
          {"nul\0byte", "nulbyte"},
          {"%2e%2e/enc", "enc"}
        ] do
      test "sanitizes #{inspect(input)} to #{expected}", %{conn: conn, user: user, vault: vault} do
        body = conn |> post("/api/folders", %{"folder" => unquote(input)}) |> json_response(201)
        assert body["folder"]["name"] == unquote(expected)

        {:ok, names} = Engram.Notes.list_explicit_folders(Engram.Repo.reload!(user), vault)
        assert names == [unquote(expected)]
      end
    end

    test "a folder that sanitizes to the root is rejected with 422", %{conn: conn} do
      for bad <- ["..", "/", "%2e%2e", "./.."] do
        assert conn |> post("/api/folders", %{"folder" => bad}) |> json_response(422)
      end
    end

    test "requires authentication" do
      conn = build_conn() |> post("/api/folders", %{"folder" => "X"})
      assert response(conn, 401)
    end
  end

  describe "DELETE /folders/*path" do
    test "returns 204 after deleting an existing marker", %{conn: conn} do
      _ = post(conn, ~p"/api/folders", %{"folder" => "Doomed"})
      conn = delete(conn, ~p"/api/folders/Doomed")
      assert response(conn, 204)
    end

    test "returns 204 when no marker exists (idempotent)", %{conn: conn} do
      conn = delete(conn, ~p"/api/folders/Ghost")
      assert response(conn, 204)
    end

    test "URI-encoded segments are decoded", %{conn: conn} do
      _ = post(conn, ~p"/api/folders", %{"folder" => "Has Space/Sub"})
      conn = delete(conn, "/api/folders/Has%20Space/Sub")
      assert response(conn, 204)
    end

    test "broadcasts folders.batch delete on the sync channel", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      _ = post(conn, ~p"/api/folders", %{"folder" => "Live/Gone"})
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      delete(conn, ~p"/api/folders/Live/Gone")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "folders.batch",
        payload: %{op: "delete", folder: "Live/Gone"}
      }
    end

    test "does NOT broadcast when nothing was deleted (no phantom delete event)", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      assert response(delete(conn, ~p"/api/folders/NeverExisted"), 204)

      refute_receive %Phoenix.Socket.Broadcast{event: "folders.batch"}, 100
    end

    test "recursive=true deletes a marker-less folder's notes", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, child} = Engram.Notes.upsert_note(user, vault, %{path: "Derived/a.md"}, actor: "api")

      assert response(delete(conn, ~p"/api/folders/Derived?recursive=true"), 204)
      assert {:error, :not_found} = Engram.Notes.get_note_by_id(user, vault, child.id)
    end

    test "recursive=true broadcasts folders.batch delete", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _} = Engram.Notes.upsert_note(user, vault, %{path: "Derived/a.md"}, actor: "api")
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      delete(conn, ~p"/api/folders/Derived?recursive=true")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "folders.batch",
        payload: %{op: "delete", folder: "Derived"}
      }
    end

    test "recursive=1 cascades too (an unrecognized value would silently no-op)", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, child} = Engram.Notes.upsert_note(user, vault, %{path: "Derived/a.md"}, actor: "api")

      assert response(delete(conn, ~p"/api/folders/Derived?recursive=1"), 204)
      assert {:error, :not_found} = Engram.Notes.get_note_by_id(user, vault, child.id)
    end

    test "without recursive, a populated folder keeps its notes", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, child} = Engram.Notes.upsert_note(user, vault, %{path: "Derived/a.md"}, actor: "api")

      assert response(delete(conn, ~p"/api/folders/Derived"), 204)
      assert {:ok, _} = Engram.Notes.get_note_by_id(user, vault, child.id)
    end
  end
end
