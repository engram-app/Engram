defmodule EngramWeb.FolderTargetSanitizeTest do
  @moduledoc """
  Rename/move TARGET paths get the same PathSanitizer rewrite note paths do:
  traversal, absolute, null-byte and percent-encoded dot segments are cleaned,
  never written as given. A non-empty target that cleans to "" is a 422, not a
  silent move to the vault root.
  """
  use EngramWeb.ConnCase, async: true

  alias Engram.Notes

  setup :authed_api_conn

  @cases [
    {"../evil", "evil"},
    {"/abs", "abs"},
    {"a/../../b", "a/b"},
    {"nul\0byte", "nulbyte"},
    {"%2e%2e/enc", "enc"}
  ]
  @empties ["..", "%2e%2e", "./.."]

  defp idem(conn), do: put_req_header(conn, "x-idempotency-key", Ecto.UUID.generate())

  defp path_of(user, vault, id) do
    {:ok, note} = Notes.get_note_by_id(Engram.Repo.reload!(user), vault, id)
    note.path
  end

  describe "POST /api/folders/rename new_path" do
    for {input, expected} <- @cases do
      test "#{inspect(input)} -> #{expected}", %{conn: conn, user: user, vault: vault} do
        {:ok, n} = Notes.upsert_note(user, vault, %{path: "Docs/n.md"}, actor: "api")

        body =
          conn
          |> post(~p"/api/folders/rename", %{"old_path" => "Docs", "new_path" => unquote(input)})
          |> json_response(200)

        assert body["count"] == 1
        assert path_of(user, vault, n.id) == unquote(expected) <> "/n.md"
      end
    end

    test "a target that cleans to empty is 422 and moves nothing", ctx do
      %{conn: conn, user: user, vault: vault} = ctx
      {:ok, n} = Notes.upsert_note(user, vault, %{path: "Docs/n.md"}, actor: "api")

      for bad <- @empties do
        conn
        |> post(~p"/api/folders/rename", %{"old_path" => "Docs", "new_path" => bad})
        |> json_response(422)
      end

      assert path_of(user, vault, n.id) == "Docs/n.md"
    end
  end

  describe "POST /api/folders/batch-move target_parent" do
    for {input, expected} <- @cases do
      test "#{inspect(input)} -> #{expected}", %{conn: conn, user: user, vault: vault} do
        {:ok, marker} = Notes.create_folder_marker(user, vault, "Src")
        {:ok, n} = Notes.upsert_note(user, vault, %{path: "Src/n.md"}, actor: "api")

        conn
        |> idem()
        |> post(~p"/api/folders/batch-move", %{ids: [marker.id], target_parent: unquote(input)})
        |> json_response(200)

        assert path_of(user, vault, n.id) == unquote(expected) <> "/Src/n.md"
      end
    end

    test "a target that cleans to empty is 422 and moves nothing", ctx do
      %{conn: conn, user: user, vault: vault} = ctx
      {:ok, marker} = Notes.create_folder_marker(user, vault, "Src")
      {:ok, n} = Notes.upsert_note(user, vault, %{path: "Src/n.md"}, actor: "api")

      for bad <- @empties do
        conn
        |> idem()
        |> post(~p"/api/folders/batch-move", %{ids: [marker.id], target_parent: bad})
        |> json_response(422)
      end

      assert path_of(user, vault, n.id) == "Src/n.md"
    end
  end

  describe "POST /api/notes/batch-move target_folder" do
    for {input, expected} <- @cases do
      test "#{inspect(input)} -> #{expected}", %{conn: conn, user: user, vault: vault} do
        {:ok, n} = Notes.upsert_note(user, vault, %{path: "a.md"}, actor: "api")

        conn
        |> idem()
        |> post(~p"/api/notes/batch-move", %{ids: [n.id], target_folder: unquote(input)})
        |> json_response(200)

        assert path_of(user, vault, n.id) == unquote(expected) <> "/a.md"
      end
    end

    test "a target that cleans to empty is 422 and moves nothing", ctx do
      %{conn: conn, user: user, vault: vault} = ctx
      {:ok, n} = Notes.upsert_note(user, vault, %{path: "Keep/a.md"}, actor: "api")

      for bad <- @empties do
        conn
        |> idem()
        |> post(~p"/api/notes/batch-move", %{ids: [n.id], target_folder: bad})
        |> json_response(422)
      end

      assert path_of(user, vault, n.id) == "Keep/a.md"
    end
  end
end
