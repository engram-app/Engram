defmodule Engram.Attachments.TimeAtWritersTest do
  @moduledoc """
  Every writer of an attachment's file time writes `mtime_at`
  (`Engram.FileTime`), normalized: upload (single request and chunked),
  move (its tombstone), delete and restore. Since R25 contract step (b) no
  writer stores the `mtime` double.
  """
  use Engram.DataCase, async: false

  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Attachments.Upload
  alias Engram.Attachments.Uploads
  alias Engram.FileTime

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put(ctx, path, mtime),
    do:
      Attachments.upsert_attachment(ctx.user, ctx.vault, %{
        "path" => path,
        :content => "png",
        "mtime" => mtime
      })

  # Every row's `mtime_at`.
  defp rows(ctx, table \\ "attachments") do
    Repo.query!("SELECT mtime_at FROM #{table} WHERE vault_id = $1", [
      Ecto.UUID.dump!(ctx.vault.id)
    ]).rows
    |> Enum.map(fn [at] -> at end)
  end

  test "an upload stores the double as sent and the timestamp normalized", ctx do
    {:ok, _} = put(ctx, "s.png", 1_776_072_500.928)
    {:ok, _} = put(ctx, "ms.png", 1_776_072_500_928.0)

    assert rows(ctx) == [
             ~U[2026-04-13 09:28:20.928000Z],
             ~U[2026-04-13 09:28:20.928000Z]
           ]
  end

  test "the plugin's 0 for an unknown time is the epoch, served as 0", ctx do
    {:ok, _} = put(ctx, "z.png", 0)
    assert rows(ctx) == [~U[1970-01-01 00:00:00.000000Z]]
    {:ok, att} = Attachments.get_attachment(ctx.user, ctx.vault, "z.png")
    assert FileTime.mtime(att) === 0.0
  end

  # A legacy row with no timestamp (an out-of-range double the backfill
  # left NULL) never blocks a server-side copy.
  test "a move copies a NULL timestamp instead of failing", ctx do
    {:ok, att} = put(ctx, "old.png", 1.0)

    Repo.with_tenant!(ctx.user.id, fn ->
      Repo.update_all(from(a in Attachment, where: a.id == ^att.id), set: [mtime_at: nil])
    end)

    assert {:ok, _} = Attachments.move_attachment(ctx.user, ctx.vault, "old.png", "new.png")
    assert Enum.uniq(rows(ctx)) == [nil]
  end

  test "a move's tombstone, a delete and a restore keep the timestamp with the double", ctx do
    {:ok, _} = put(ctx, "D/a.png", 1_776_072_500_928.0)
    {:ok, _} = Attachments.move_attachment(ctx.user, ctx.vault, "D/a.png", "D/b.png")
    op = Ecto.UUID.generate()
    {:ok, _} = Engram.Folders.delete(ctx.user, ctx.vault, "D", recursive: true, op_id: op)
    {:ok, _} = Engram.Folders.restore_op(ctx.user, ctx.vault, op)

    rows = rows(ctx)
    assert length(rows) >= 2
    assert Enum.uniq(rows) == [~U[2026-04-13 09:28:20.928000Z]]
  end

  test "a chunked upload writes the session's and the attachment's timestamp", ctx do
    {:ok, %Upload{} = up} =
      Uploads.start(ctx.user, ctx.vault, %{
        path: "c.bin",
        size_bytes: 3,
        mtime: 1_776_072_500_928.0
      })

    assert up.mtime_at == ~U[2026-04-13 09:28:20.928000Z]

    assert {:error, %Ecto.Changeset{}} =
             Uploads.start(ctx.user, ctx.vault, %{path: "d.bin", size_bytes: 3, mtime: 1.0e19})

    {:ok, _} = Uploads.put_part(ctx.user, ctx.vault, up.id, 1, "abc")
    {:ok, %Attachment{} = att} = Uploads.complete(ctx.user, ctx.vault, up.id)
    assert att.mtime_at == ~U[2026-04-13 09:28:20.928000Z]

    assert Enum.uniq(rows(ctx) ++ rows(ctx, "attachment_uploads")) == [
             ~U[2026-04-13 09:28:20.928000Z]
           ]
  end
end
