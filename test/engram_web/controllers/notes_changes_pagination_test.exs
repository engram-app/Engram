defmodule EngramWeb.NotesChangesPaginationTest do
  use EngramWeb.ConnCase, async: true

  setup :authed_api_conn

  defp seed(user, vault, n) do
    for i <- 1..n do
      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          path: "n#{i}.md",
          content: "note #{i}",
          mtime: i * 1.0
        })

      note
    end
  end

  describe "GET /api/notes/changes pagination" do
    test "limit + cursor loop converges and covers all changes", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      seed(user, vault, 3)

      page1 =
        conn
        |> get(~p"/api/notes/changes?since=2020-01-01T00:00:00Z&limit=2")
        |> json_response(200)

      assert length(page1["changes"]) == 2
      assert page1["has_more"] == true
      assert is_binary(page1["next_cursor"])
      assert is_binary(page1["server_time"])

      page2 =
        conn
        |> get(
          ~p"/api/notes/changes?since=2020-01-01T00:00:00Z&limit=2&cursor=#{page1["next_cursor"]}"
        )
        |> json_response(200)

      assert length(page2["changes"]) == 1
      assert page2["has_more"] == false
      assert page2["next_cursor"] == nil

      paths = Enum.map(page1["changes"] ++ page2["changes"], & &1["path"])
      assert Enum.sort(paths) == ["n1.md", "n2.md", "n3.md"]
    end

    test "responses without explicit limit keep the legacy shape plus pagination fields", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      seed(user, vault, 1)

      body =
        conn
        |> get(~p"/api/notes/changes?since=2020-01-01T00:00:00Z")
        |> json_response(200)

      assert [change] = body["changes"]
      assert change["content"] == "note 1"
      assert is_binary(change["content_hash"])
      assert body["has_more"] == false
      assert body["next_cursor"] == nil
    end

    test "fields=meta omits content and keeps content_hash", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      seed(user, vault, 1)

      body =
        conn
        |> get(~p"/api/notes/changes?since=2020-01-01T00:00:00Z&fields=meta")
        |> json_response(200)

      assert [change] = body["changes"]
      refute Map.has_key?(change, "content")
      assert is_binary(change["content_hash"])
      assert change["path"] == "n1.md"
    end

    test "has_more responses anchor server_time at the last returned change (legacy convergence)",
         %{conn: conn, user: user, vault: vault} do
      seed(user, vault, 3)

      page1 =
        conn
        |> get(~p"/api/notes/changes?since=2020-01-01T00:00:00Z&limit=2")
        |> json_response(200)

      assert page1["has_more"] == true
      # A legacy client advances since = server_time after every poll. If
      # server_time were "now", the un-fetched tail (updated_at < now) would
      # be skipped forever — silent data loss. Anchoring server_time at the
      # last returned row makes the next inclusive since-poll resume exactly
      # at the truncation point.
      last_updated_at = page1["changes"] |> List.last() |> Map.fetch!("updated_at")
      assert page1["server_time"] == last_updated_at

      # The legacy loop converges: poll again from server_time, no cursor.
      page2 =
        conn
        |> get(~p"/api/notes/changes?since=#{page1["server_time"]}&limit=2")
        |> json_response(200)

      assert page2["has_more"] == false
      # Full final page → server_time reverts to "now" semantics (parseable,
      # >= the last change).
      assert {:ok, _, _} = DateTime.from_iso8601(page2["server_time"])

      all_paths =
        Enum.map(page1["changes"] ++ page2["changes"], & &1["path"]) |> Enum.uniq()

      assert Enum.sort(all_paths) == ["n1.md", "n2.md", "n3.md"]
    end

    test "invalid cursor → 400", %{conn: conn} do
      body =
        conn
        |> get(~p"/api/notes/changes?since=2020-01-01T00:00:00Z&cursor=!!!notacursor")
        |> json_response(400)

      assert body["error"] == "invalid_cursor"
    end

    test "invalid limit → 400", %{conn: conn} do
      assert conn
             |> get(~p"/api/notes/changes?since=2020-01-01T00:00:00Z&limit=abc")
             |> json_response(400)

      assert conn
             |> get(~p"/api/notes/changes?since=2020-01-01T00:00:00Z&limit=0")
             |> json_response(400)
    end

    test "invalid fields value → 400", %{conn: conn} do
      assert conn
             |> get(~p"/api/notes/changes?since=2020-01-01T00:00:00Z&fields=everything")
             |> json_response(400)
    end
  end
end
