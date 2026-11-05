defmodule Engram.Attachments.TimeAtWritersTest do
  @moduledoc """
  Every writer of `attachments.mtime` / `attachment_uploads.mtime` also
  writes `mtime_at` (`Engram.FileTime`): upload (single request and
  chunked), move (its tombstone), delete and restore. The double is stored
  as sent; `mtime_at == FileTime.to_at(mtime)` on every row.
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

  defp rows(ctx) do
    Repo.with_tenant!(ctx.user.id, fn ->
      Repo.all(
        from(a in Attachment, where: a.vault_id == ^ctx.vault.id, select: {a.mtime, a.mtime_at})
      )
    end)
  end

  defp assert_parity!(ctx) do
    rows = rows(ctx)
    assert rows != []
    for {mtime, at} <- rows, do: assert({:ok, at} == FileTime.to_at(mtime), inspect(mtime))
    length(rows)
  end

  test "an upload stores the double as sent and the timestamp normalized", ctx do
    {:ok, _} = put(ctx, "s.png", 1_776_072_500.928)
    {:ok, _} = put(ctx, "ms.png", 1_776_072_500_928.0)

    assert Enum.sort(rows(ctx)) == [
             {1_776_072_500.928, ~U[2026-04-13 09:28:20.928000Z]},
             {1_776_072_500_928.0, ~U[2026-04-13 09:28:20.928000Z]}
           ]
  end

  test "the plugin's 0 for an unknown time is a NULL timestamp", ctx do
    {:ok, _} = put(ctx, "z.png", 0)
    assert rows(ctx) == [{0.0, nil}]
  end

  # A legacy out-of-range double (REST refuses new ones with a 422) never
  # blocks a server-side copy: the move's tombstone gets a NULL timestamp.
  test "a move copies a legacy out-of-range time instead of failing", ctx do
    {:ok, att} = put(ctx, "old.png", 1.0)

    Repo.with_tenant!(ctx.user.id, fn ->
      Repo.update_all(from(a in Attachment, where: a.id == ^att.id), set: [mtime: 1.0e19])
    end)

    assert {:ok, _} = Attachments.move_attachment(ctx.user, ctx.vault, "old.png", "new.png")
    assert {1.0e19, nil} in rows(ctx)
  end

  test "a move's tombstone, a delete and a restore keep the timestamp with the double", ctx do
    {:ok, _} = put(ctx, "D/a.png", 1_776_072_500_928.0)
    {:ok, _} = Attachments.move_attachment(ctx.user, ctx.vault, "D/a.png", "D/b.png")
    op = Ecto.UUID.generate()
    {:ok, _} = Engram.Folders.delete(ctx.user, ctx.vault, "D", recursive: true, op_id: op)
    {:ok, _} = Engram.Folders.restore_op(ctx.user, ctx.vault, op)

    assert assert_parity!(ctx) >= 2
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
    assert {att.mtime, att.mtime_at} == {1_776_072_500_928.0, ~U[2026-04-13 09:28:20.928000Z]}
  end
end
