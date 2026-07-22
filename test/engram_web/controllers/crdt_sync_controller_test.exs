defmodule EngramWeb.CrdtSyncControllerTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Notes

  setup :authed_api_conn

  defp seed_note(user, vault, path, content) do
    {:ok, note} = Notes.upsert_note(user, vault, %{path: path, content: content, mtime: 1_000.0})
    note
  end

  describe "REST /updates endpoints are DELETED (Phase E3 — socket is the only Yjs path)" do
    # The dedicated routes are gone; the requests now fall through to the
    # `/notes/*path` wildcard (a nonexistent note path) or the router's 404.
    # The contract pinned here: no Yjs delta is ever SERVED or APPLIED over
    # REST — a request to the old paths yields a plain 404 with no transport
    # payload.
    test "GET /api/notes/:id/updates no longer serves a delta", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      note = seed_note(user, vault, "T/A.md", "# A")

      body = conn |> get("/api/notes/#{note.id}/updates") |> json_response(404)
      refute Map.has_key?(body, "update")
      refute Map.has_key?(body, "head")
    end

    test "POST /api/notes/:id/updates no longer applies an update", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      note = seed_note(user, vault, "T/B.md", "# B")

      resp = post(conn, "/api/notes/#{note.id}/updates", %{update: Base.encode64(<<0, 0>>)})
      assert resp.status == 404
      refute Map.has_key?(Jason.decode!(resp.resp_body), "head")
    end
  end

  describe "GET /api/vault/heads" do
    test "returns a marker map covering the vault's notes",
         %{conn: conn, user: user, vault: vault} do
      a = seed_note(user, vault, "H/A.md", "# A")
      b = seed_note(user, vault, "H/B.md", "# B")

      heads = conn |> get("/api/vault/heads") |> json_response(200) |> Map.fetch!("heads")
      assert %{"path" => "H/A.md", "head" => ha} = heads[a.id]
      assert %{"path" => "H/B.md", "head" => hb} = heads[b.id]
      assert is_binary(ha) and is_binary(hb)
    end
  end
end
