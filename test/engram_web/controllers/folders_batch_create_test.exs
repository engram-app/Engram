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
  end
end
