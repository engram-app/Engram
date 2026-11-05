defmodule EngramWeb.FileTimeReadersTest do
  @moduledoc """
  R25 migrate-data: every reader of `notes.mtime` / `ctime` and
  `attachments.mtime` sends `Engram.FileTime.epoch/2` of the `*_at` column.
  The wire format is unchanged (epoch seconds): a seconds double goes out
  bit-identical, a millisecond double goes out as seconds, and a row the
  backfill has not reached yet (`*_at` NULL) sends its double as stored.
  """
  use EngramWeb.ConnCase, async: false

  alias Engram.Attachments.Attachment
  alias Engram.Notes.Note
  alias Engram.Repo

  setup :authed_api_conn

  @s 1_776_072_500.928
  @ms 1_776_072_500_928.0

  defp post_note(conn, path, times),
    do:
      conn
      |> post("/api/notes", Map.merge(%{path: path, content: "x\n"}, times))
      |> json_response(200)

  defp post_att(conn, path, mtime),
    do:
      conn
      |> post("/api/attachments", %{path: path, content_base64: Base.encode64("B"), mtime: mtime})
      |> json_response(200)

  defp unbackfill(user, schema) do
    Repo.with_tenant!(user.id, fn ->
      case schema do
        Note -> Repo.update_all(Note, set: [mtime_at: nil, ctime_at: nil])
        Attachment -> Repo.update_all(Attachment, set: [mtime_at: nil])
      end
    end)
  end

  defp notes_by_path(list), do: Map.new(list, &{&1["path"], &1})

  describe "notes" do
    setup %{conn: conn} do
      post_note(conn, "s.md", %{mtime: @s, ctime: 1_510_897_528.861})
      post_note(conn, "ms.md", %{mtime: @ms, ctime: 1_510_897_528_861.0})
      :ok
    end

    test "GET /notes/*path: seconds bit-identical, milliseconds as seconds", %{conn: conn} do
      s = conn |> get("/api/notes/s.md") |> json_response(200)
      assert {s["mtime"], s["ctime"]} === {@s, 1_510_897_528.861}

      ms = conn |> get("/api/notes/ms.md") |> json_response(200)
      assert {ms["mtime"], ms["ctime"]} === {@s, 1_510_897_528.861}
    end

    test "before the backfill (NULL *_at) the double goes out as stored", %{
      conn: conn,
      user: user
    } do
      unbackfill(user, Note)
      ms = conn |> get("/api/notes/ms.md") |> json_response(200)
      assert {ms["mtime"], ms["ctime"]} === {@ms, 1_510_897_528_861.0}
    end

    test "the seq change feed and the folder listing send the same value", ctx do
      %{conn: conn, user: user, vault: vault} = ctx
      {:ok, user} = Engram.Crypto.ensure_user_dek(Repo.reload!(user))
      {:ok, %{changes: changes}} = Engram.Notes.list_changes_by_seq(user, vault, 0, fields: :meta)
      feed = Map.new(changes, &{&1.path, &1})
      assert feed["ms.md"].mtime === @s
      assert feed["s.md"].mtime === @s

      listing = conn |> get("/api/folders/list?folder=") |> json_response(200)
      listing = notes_by_path(listing["notes"])
      assert listing["ms.md"]["mtime"] === @s
      assert listing["s.md"]["mtime"] === @s
    end
  end

  describe "attachments" do
    setup %{conn: conn} do
      post_att(conn, "s.png", @s)
      post_att(conn, "ms.png", @ms)
      :ok
    end

    test "show, raw headers and the listing", %{conn: conn} do
      assert (conn |> get("/api/attachments/s.png") |> json_response(200))["mtime"] === @s
      assert (conn |> get("/api/attachments/ms.png") |> json_response(200))["mtime"] === @s

      raw = get(conn, "/api/attachments/ms.png?raw=1")
      assert get_resp_header(raw, "x-engram-mtime") == [Jason.encode!(@s)]

      list = conn |> get("/api/attachments") |> json_response(200)
      list = notes_by_path(list["attachments"])
      assert list["ms.png"]["mtime"] === @s
      assert list["s.png"]["mtime"] === @s
    end

    test "before the backfill (NULL mtime_at) the double goes out as stored", %{
      conn: conn,
      user: user
    } do
      unbackfill(user, Attachment)
      assert (conn |> get("/api/attachments/ms.png") |> json_response(200))["mtime"] === @ms
    end
  end
end
