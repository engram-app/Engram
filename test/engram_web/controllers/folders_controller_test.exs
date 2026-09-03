defmodule EngramWeb.FoldersControllerTest do
  use EngramWeb.ConnCase, async: true

  setup :authed_api_conn

  describe "POST /api/folders/rename" do
    test "rename cascades to attachments", %{conn: conn, user: user, vault: vault} do
      {:ok, _att} =
        Engram.Attachments.upsert_attachment(user, vault, %{
          "path" => "Docs/a.txt",
          "content_base64" => Base.encode64("hello")
        })

      conn
      |> post(~p"/api/folders/rename", %{"old_path" => "Docs", "new_path" => "Archive"})
      |> json_response(200)

      {:ok, metas} = Engram.Attachments.list_attachments(user, vault)
      assert Enum.map(metas, & &1.path) == ["Archive/a.txt"]
    end
  end

  describe "GET /api/folders" do
    test "response includes id and parent_id per folder marker", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      {:ok, _parent} = Engram.Notes.create_folder_marker(user, vault, "Projects")
      {:ok, _child} = Engram.Notes.create_folder_marker(user, vault, "Projects/Engram")

      body = conn |> get(~p"/api/folders") |> json_response(200)

      parent = Enum.find(body["folders"], &(&1["name"] == "Projects"))
      child = Enum.find(body["folders"], &(&1["name"] == "Projects/Engram"))

      assert is_binary(parent["id"])
      assert parent["parent_id"] == nil
      assert is_binary(child["id"])
      assert child["parent_id"] == parent["id"]
    end
  end

  describe "GET /api/folders/by-id/:id/notes" do
    test "returns notes inside the folder", %{conn: conn, user: user, vault: vault} do
      {:ok, marker} = Engram.Notes.create_folder_marker(user, vault, "Projects")

      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{path: "Projects/a.md", content: "# A"})

      body = conn |> get(~p"/api/folders/by-id/#{marker.id}/notes") |> json_response(200)

      assert [%{"path" => "Projects/a.md", "id" => _}] = body["notes"]
    end

    # This describe block used to hold ONE negative case, named "404 when marker
    # doesn't belong to caller's vault" but passing a freshly generated UUID —
    # an id belonging to NO vault. That proves the not-found path, not the
    # scoping one: a controller that looked markers up globally and ignored the
    # caller's vault entirely would still have passed it. The two cases the
    # name actually claims are below, and neither was covered.
    test "404 for a marker id that does not exist" do
      %{conn: conn} = authed_api_conn(%{conn: build_conn()})

      conn |> get(~p"/api/folders/by-id/#{Ecto.UUID.generate()}/notes") |> json_response(404)
    end

    # Defended by RLS (`Repo.with_tenant/2`), not by the query's vault
    # predicate — verified by mutation: dropping `vault_id` from
    # `get_folder_marker_by_id/3` leaves this test green. Kept anyway as the
    # boundary marker for THIS endpoint (multi_tenant_test.exs covers notes,
    # folders, tags and the manifest, but not folder-notes-by-id).
    test "404 when the marker belongs to another user's vault" do
      %{conn: conn} = authed_api_conn(%{conn: build_conn()})
      %{user: other_user, vault: other_vault} = authed_api_conn(%{conn: build_conn()})

      {:ok, marker} = Engram.Notes.create_folder_marker(other_user, other_vault, "Theirs")

      {:ok, _} =
        Engram.Notes.upsert_note(other_user, other_vault, %{
          path: "Theirs/secret.md",
          content: "# Secret"
        })

      conn |> get(~p"/api/folders/by-id/#{marker.id}/notes") |> json_response(404)
    end

    # The subtler half, and the one the old test's name pointed at most
    # directly: same owner, different vault. Tenant scoping alone (user_id /
    # RLS) does NOT catch this — both vaults belong to the caller — so this is
    # the ONLY test here that exercises the vault predicate itself.
    #
    # Verified by mutation: rewriting `get_folder_marker_by_id/3` to scope by
    # `user_id` alone (a realistic dropped-clause bug, and the exact shape
    # `tenant_scope_lint_test.exs` exists to catch elsewhere) turns this into a
    # 200 with the other vault's folder listing. The other two cases in this
    # block stay green under that mutation.
    test "404 when the marker belongs to another vault of the same user", %{
      conn: conn,
      user: user
    } do
      other_vault = Engram.Factory.insert(:vault, user: user, is_default: false)

      {:ok, marker} = Engram.Notes.create_folder_marker(user, other_vault, "OtherVault")

      {:ok, _} =
        Engram.Notes.upsert_note(user, other_vault, %{
          path: "OtherVault/a.md",
          content: "# A"
        })

      conn |> get(~p"/api/folders/by-id/#{marker.id}/notes") |> json_response(404)
    end
  end
end
