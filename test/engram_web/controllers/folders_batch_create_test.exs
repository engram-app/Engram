defmodule EngramWeb.FoldersBatchCreateTest do
  use EngramWeb.ConnCase, async: true

  setup :authed_api_conn

  defp names(body), do: body["folders"] |> Enum.map(& &1["name"]) |> Enum.sort()

  # Reload: the request may have minted the user's DEK after setup built `user`.
  defp explicit(user, vault) do
    {:ok, names} = Engram.Notes.list_explicit_folders(Engram.Repo.reload!(user), vault)
    Enum.sort(names)
  end

  describe "POST /api/folders/batch" do
    test "creates every folder in one call", %{conn: conn, user: user, vault: vault} do
      body =
        conn
        |> post(~p"/api/folders/batch", %{folders: ["A", "B/C", "D"]})
        |> json_response(201)

      assert names(body) == ["A", "B/C", "D"]
      assert Enum.all?(body["folders"], &(&1["count"] == 0))
      assert explicit(user, vault) == ["A", "B/C", "D"]
    end

    test "idempotent: existing and duplicate folders are not errors", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _} = Engram.Notes.create_folder_marker(user, vault, "Old")

      body =
        conn
        |> post(~p"/api/folders/batch", %{folders: ["Old", "New", "New"]})
        |> json_response(201)

      assert names(body) == ["New", "Old"]
      assert explicit(user, vault) == ["New", "Old"]
    end

    test "one folders.batch broadcast for the whole batch", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      post(conn, ~p"/api/folders/batch", %{folders: ["X", "Y"]})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "folders.batch",
        payload: %{op: "create", folders: folders}
      }

      assert Enum.sort(folders) == ["X", "Y"]
      refute_receive %Phoenix.Socket.Broadcast{event: "folders.batch"}
    end

    test "sanitizes traversal and drops entries that sanitize to empty", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      body =
        conn
        |> post(~p"/api/folders/batch", %{folders: ["../../etc", "a/../b", "..", "", "/"]})
        |> json_response(201)

      assert names(body) == ["a/b", "etc"]
      refute Enum.any?(explicit(user, vault), &String.contains?(&1, ".."))
    end

    test "rejects more than 500 folders with 422", %{conn: conn, user: user, vault: vault} do
      folders = Enum.map(1..501, &"F#{&1}")

      body = conn |> post(~p"/api/folders/batch", %{folders: folders}) |> json_response(422)

      assert body["error"] == "batch_too_large"
      assert explicit(user, vault) == []
    end

    test "accepts exactly 500 folders", %{conn: conn} do
      folders = Enum.map(1..500, &"F#{&1}")
      body = conn |> post(~p"/api/folders/batch", %{folders: folders}) |> json_response(201)
      assert length(body["folders"]) == 500
    end

    test "non-string entries or missing param are 422", %{conn: conn} do
      assert conn |> post(~p"/api/folders/batch", %{folders: ["ok", 1]}) |> json_response(422)
      assert conn |> post(~p"/api/folders/batch", %{}) |> json_response(422)
      assert conn |> post(~p"/api/folders/batch", %{folders: "A"}) |> json_response(422)
    end

    test "requires authentication" do
      conn = build_conn() |> post(~p"/api/folders/batch", %{folders: ["X"]})
      assert response(conn, 401)
    end

    test "writes only to the caller's vault", %{conn: conn, user: user, vault: vault} do
      other = insert(:user)
      other_vault = insert(:vault, user: other, is_default: true)
      {:ok, _} = Engram.Notes.create_folder_marker(other, other_vault, "Shared")

      conn |> post(~p"/api/folders/batch", %{folders: ["Shared", "Mine"]}) |> json_response(201)

      assert explicit(user, vault) == ["Mine", "Shared"]
      assert explicit(other, other_vault) == ["Shared"]
    end

    # The plugin records the SERVER name per input so a folder the server
    # rewrote is not trashed or re-sent on its next reconcile.
    test "returns each input with the name it was stored under", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/folders/batch", %{folders: ["a/../b", "x%252Fy", "Plain", "Plain"]})
        |> json_response(201)

      pairs = body["folders"] |> Enum.map(&{&1["input"], &1["name"]}) |> Enum.sort()
      assert pairs == [{"Plain", "Plain"}, {"a/../b", "a/b"}, {"x%252Fy", "x/y"}]
    end

    test "inputs that sanitize to the root come back as rejected", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/folders/batch", %{folders: ["..", "", "/", "ok"]})
        |> json_response(201)

      assert Enum.sort(body["rejected"]) == ["", "..", "/"]
      assert Enum.map(body["folders"], & &1["input"]) == ["ok"]
    end

    test "broadcasts only folders it created or undeleted", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _} = Engram.Notes.create_folder_marker(user, vault, "Old")
      {:ok, _} = Engram.Notes.create_folder_marker(user, vault, "Gone")

      {:ok, :deleted} =
        Engram.Notes.delete_folder_marker(Engram.Repo.reload!(user), vault, "Gone")

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      post(conn, ~p"/api/folders/batch", %{folders: ["Old", "Gone", "New"]})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "folders.batch",
        payload: %{op: "create", folders: folders}
      }

      assert Enum.sort(folders) == ["Gone", "New"]
    end

    test "an all-existing batch broadcasts nothing and takes no seq", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _} = Engram.Notes.create_folder_marker(user, vault, "Old")
      before = Engram.Vaults.current_seq(user.id, vault.id)
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      body = conn |> post(~p"/api/folders/batch", %{folders: ["Old"]}) |> json_response(201)

      assert [%{"input" => "Old", "name" => "Old"}] = body["folders"]
      refute_receive %Phoenix.Socket.Broadcast{event: "folders.batch"}, 100
      assert Engram.Vaults.current_seq(user.id, vault.id) == before
    end
  end

  # Lock order: every note writer takes the vault row lock BEFORE its first
  # note row write. The batch takes it lazily, but never after a write.
  describe "create_folder_markers/3 lock order" do
    test "takes the vault lock after the reads, before the first write", %{
      user: user,
      vault: vault
    } do
      {:ok, _} = Engram.Notes.create_folder_marker(user, vault, "Old")
      user = Engram.Repo.reload!(user)

      queries =
        Engram.TenantQueryCounter.count_matching_queries(
          fn -> {:ok, _} = Engram.Notes.create_folder_markers(user, vault, ["Old", "New"]) end,
          fn _ -> true end
        )

      first_read = Enum.find_index(queries, &(&1 =~ ~s(FROM "notes")))
      seq_at = Enum.find_index(queries, &(&1 =~ "change_seq = change_seq + 1"))
      insert_at = Enum.find_index(queries, &(&1 =~ ~s(INSERT INTO "notes")))

      assert first_read && seq_at && insert_at, Enum.join(queries, "\n")
      assert first_read < seq_at, Enum.join(queries, "\n")
      assert seq_at < insert_at, Enum.join(queries, "\n")
    end
  end
end
