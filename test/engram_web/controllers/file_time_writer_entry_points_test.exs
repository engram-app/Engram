defmodule EngramWeb.FileTimeWriterEntryPointsTest do
  @moduledoc """
  R25 acceptance: the 12 real prod desktop mtimes
  (`Engram.FileTimeFixtures`) through every client entry point that stores
  a file time, each twin the ROUNDED `FileTime.to_at/1` of its double:
  plugin push and web create (`POST /api/notes`, the one note upsert both
  use), the ctime batch (`POST /api/notes/ctime`), attachment upload
  (`POST /api/attachments`) and the chunked upload session plus its
  finalize. MCP `write_note` sends the server's own time, a whole second.
  The CRDT checkpoint writes no file time. Twins are compared as sorted
  sets: the doubles are no longer stored to key them by.
  """
  use EngramWeb.ConnCase, async: false

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Attachments.Upload
  alias Engram.Attachments.Uploads
  alias Engram.FileTime
  alias Engram.FileTimeFixtures
  alias Engram.MCP.Handlers
  alias Engram.Notes.Note
  alias Engram.Repo

  setup :authed_api_conn

  @times FileTimeFixtures.prod_desktop_times()

  defp twins(user, schema, select) do
    Repo.with_tenant!(user.id, fn -> Repo.all(from(r in schema, select: ^select)) end)
  end

  defp sorted(rows, field), do: rows |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sort(DateTime)
  defp want, do: @times |> Enum.map(&FileTimeFixtures.rounded_twin/1) |> Enum.sort(DateTime)

  test "POST /api/notes (plugin push, web create): mtime and ctime twins", ctx do
    for {{t, _}, i} <- Enum.with_index(@times) do
      ctx.conn
      |> post("/api/notes", %{path: "n#{i}.md", content: "x\n", mtime: t, ctime: t})
      |> json_response(200)
    end

    rows = twins(ctx.user, Note, [:mtime_at, :ctime_at])
    assert sorted(rows, :mtime_at) == want()
    assert sorted(rows, :ctime_at) == want()
  end

  test "POST /api/notes/ctime: the batch writes rounded twins", ctx do
    entries =
      for {{t, _}, i} <- Enum.with_index(@times) do
        ctx.conn |> post("/api/notes", %{path: "c#{i}.md", content: "x\n"}) |> json_response(200)
        %{path: "c#{i}.md", ctime: t}
      end

    assert %{"updated" => 12} =
             ctx.conn |> post("/api/notes/ctime", %{entries: entries}) |> json_response(200)

    assert ctx.user |> twins(Note, [:ctime_at]) |> sorted(:ctime_at) == want()
  end

  test "POST /api/attachments: upload twins", ctx do
    for {{t, _}, i} <- Enum.with_index(@times) do
      ctx.conn
      |> post("/api/attachments", %{
        path: "a#{i}.png",
        content_base64: Base.encode64("B#{i}"),
        mtime: t
      })
      |> json_response(200)
    end

    assert ctx.user |> twins(Attachment, [:mtime_at]) |> sorted(:mtime_at) == want()
  end

  test "chunked upload: the session and the finalized attachment", ctx do
    for {{t, _} = v, i} <- Enum.with_index(@times) do
      {:ok, %Upload{} = up} =
        Uploads.start(ctx.user, ctx.vault, %{path: "u#{i}.bin", size_bytes: 3, mtime: t})

      {:ok, _} = Uploads.put_part(ctx.user, ctx.vault, up.id, 1, "abc")
      {:ok, %Attachment{} = att} = Uploads.complete(ctx.user, ctx.vault, up.id)

      want = FileTimeFixtures.rounded_twin(v)
      assert {up.mtime_at, att.mtime_at} == {want, want}, inspect(t)
    end

    assert ctx.user |> twins(Upload, [:mtime_at]) |> sorted(:mtime_at) == want()
  end

  test "MCP write_note: the server's time, twin rounded from its double", ctx do
    {:ok, user} = Engram.Crypto.ensure_user_dek(Repo.reload!(ctx.user))

    assert {:ok, _, _} =
             Handlers.handle("write_note", user, ctx.vault, %{"path" => "m.md", "content" => "x"})

    [row] = twins(user, Note, [:mtime_at])
    assert row.mtime_at.microsecond == {0, 6}
    assert abs(DateTime.diff(row.mtime_at, DateTime.utc_now())) < 60
  end
end
