defmodule EngramWeb.FileTimeWriterEntryPointsTest do
  @moduledoc """
  R25 acceptance: the 12 real prod desktop mtimes
  (`Engram.FileTimeFixtures`) through every client entry point that stores
  a file time, each twin the ROUNDED `FileTime.to_at/1` of its double:
  plugin push and web create (`POST /api/notes`, the one note upsert both
  use), the ctime batch (`POST /api/notes/ctime`), attachment upload
  (`POST /api/attachments`) and the chunked upload session plus its
  finalize. MCP `write_note` sends the server's own time, so its twin is
  checked against its stored double. The CRDT checkpoint writes no file
  time.
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

  defp by_double(rows, field), do: Map.new(rows, &{Map.fetch!(&1, field), &1})

  test "POST /api/notes (plugin push, web create): mtime and ctime twins", ctx do
    for {{t, _} = v, i} <- Enum.with_index(@times) do
      ctx.conn
      |> post("/api/notes", %{path: "n#{i}.md", content: "x\n", mtime: t, ctime: t})
      |> json_response(200)

      [row] =
        twins(ctx.user, Note, [:mtime, :mtime_at, :ctime, :ctime_at])
        |> Enum.filter(&(&1.mtime == t))

      want = FileTimeFixtures.rounded_twin(v)
      assert {row.mtime_at, row.ctime_at} == {want, want}, inspect(t)
    end
  end

  test "POST /api/notes/ctime: the batch writes rounded twins", ctx do
    entries =
      for {{t, _}, i} <- Enum.with_index(@times) do
        ctx.conn |> post("/api/notes", %{path: "c#{i}.md", content: "x\n"}) |> json_response(200)
        %{path: "c#{i}.md", ctime: t}
      end

    assert %{"updated" => 12} =
             ctx.conn |> post("/api/notes/ctime", %{entries: entries}) |> json_response(200)

    rows = ctx.user |> twins(Note, [:ctime, :ctime_at]) |> by_double(:ctime)

    for {t, _} = v <- @times,
        do: assert(rows[t].ctime_at == FileTimeFixtures.rounded_twin(v), inspect(t))
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

    rows = ctx.user |> twins(Attachment, [:mtime, :mtime_at]) |> by_double(:mtime)

    for {t, _} = v <- @times,
        do: assert(rows[t].mtime_at == FileTimeFixtures.rounded_twin(v), inspect(t))
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

    rows = ctx.user |> twins(Upload, [:mtime, :mtime_at]) |> by_double(:mtime)

    for {t, _} = v <- @times,
        do: assert(rows[t].mtime_at == FileTimeFixtures.rounded_twin(v), inspect(t))
  end

  test "MCP write_note: the server's time, twin rounded from its double", ctx do
    {:ok, user} = Engram.Crypto.ensure_user_dek(Repo.reload!(ctx.user))

    assert {:ok, _, _} =
             Handlers.handle("write_note", user, ctx.vault, %{"path" => "m.md", "content" => "x"})

    [row] = twins(user, Note, [:mtime, :mtime_at])
    assert row.mtime_at == FileTime.normalize(row.mtime)
  end
end
