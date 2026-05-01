defmodule EngramWeb.MissingFeaturesTest do
  @moduledoc """
  TDD tests for features that were originally missing from the Elixir backend.
  These tests should FAIL initially, then pass after implementation.
  """
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user}
  end

  # ---------------------------------------------------------------------------
  # REST rename endpoint  # ---------------------------------------------------------------------------

  describe "POST /notes/rename" do
    test "renames a note and returns updated metadata", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Original.md", content: "# Original", mtime: 1_000.0})

      conn2 =
        post(conn, "/api/notes/rename", %{
          old_path: "Test/Original.md",
          new_path: "Test/Renamed.md"
        })

      assert %{"note" => note} = json_response(conn2, 200)
      assert note["path"] == "Test/Renamed.md"
      assert note["folder"] == "Test"
    end

    test "returns 404 for nonexistent source", %{conn: conn} do
      conn =
        post(conn, "/api/notes/rename", %{
          old_path: "Nope/Missing.md",
          new_path: "Nope/New.md"
        })

      assert json_response(conn, 404)
    end

    test "old path returns 404 after rename", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/MoveSrc.md", content: "# Move", mtime: 1_000.0})

      post(conn, "/api/notes/rename", %{
        old_path: "Test/MoveSrc.md",
        new_path: "Test/MoveDst.md"
      })

      conn2 = get(conn, "/api/notes/Test/MoveSrc.md")
      assert json_response(conn2, 404)
    end

    test "new path is readable after rename", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Src.md", content: "# Content Here", mtime: 1_000.0})

      post(conn, "/api/notes/rename", %{
        old_path: "Test/Src.md",
        new_path: "New Folder/Dst.md"
      })

      conn2 = get(conn, "/api/notes/New Folder/Dst.md")
      body = json_response(conn2, 200)
      assert body["content"] =~ "Content Here"
      assert body["folder"] == "New Folder"
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/notes/rename", %{old_path: "a.md", new_path: "b.md"})

      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # Note size limit  # ---------------------------------------------------------------------------

  describe "note size limit" do
    test "rejects notes over 10MB with 413", %{conn: conn} do
      huge_content = String.duplicate("x", 10 * 1024 * 1024 + 1)

      conn =
        post(conn, "/api/notes", %{
          path: "Test/Huge.md",
          content: huge_content,
          mtime: 1_000.0
        })

      assert conn.status == 413
    end
  end

  # ---------------------------------------------------------------------------
  # CORS  # ---------------------------------------------------------------------------

  describe "CORS" do
    test "OPTIONS on /notes returns CORS headers", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> put_req_header("origin", "app://obsidian")
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header("access-control-request-headers", "authorization,content-type")
        |> options("/api/notes")

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") != []
      assert get_resp_header(conn, "access-control-allow-headers") != []
    end

    test "actual request includes CORS origin header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "app://obsidian")
        |> get("/api/health")

      assert get_resp_header(conn, "access-control-allow-origin") != []
    end
  end

  # ---------------------------------------------------------------------------
  # API key revocation  # ---------------------------------------------------------------------------

  describe "DELETE /api-keys/:id" do
    test "revokes an API key (session auth)", %{user: user} do
      # API-key auth is no longer permitted on /api-keys/* — must use a
      # session JWT. See EngramWeb.Plugs.RequireSession.
      user_with_ext =
        if user.external_id in [nil, ""] do
          {:ok, u} =
            user
            |> Ecto.Changeset.change(external_id: "test-#{user.id}")
            |> Engram.Repo.update(skip_tenant_check: true)

          u
        else
          user
        end

      {:ok, jwt} =
        Engram.Auth.Providers.Local.issue_access_token(
          user_with_ext.external_id,
          user_with_ext.email
        )

      session_conn = build_conn() |> put_req_header("authorization", "Bearer #{jwt}")

      {:ok, temp_key, temp_api_key} = Engram.Accounts.create_api_key(user, "temp-key")

      conn2 = delete(session_conn, "/api/api-keys/#{temp_api_key.id}")
      assert json_response(conn2, 200)

      # Revoked key should be rejected
      conn3 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{temp_key}")
        |> get("/api/tags")

      assert json_response(conn3, 401)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> delete("/api/api-keys/999")

      assert json_response(conn, 401)
    end
  end
end
