defmodule Engram.Notes.TimeAtWritersTest do
  @moduledoc """
  Every writer of a note's file times writes `mtime_at` / `ctime_at`
  (`Engram.FileTime`), normalized, and since R25 contract step (b) never
  the `mtime` / `ctime` doubles: no row of the vault (live, tombstone,
  folder marker) holds one. A copy (rename, restore, edit, tombstone)
  keeps the timestamp.
  """
  use Engram.DataCase, async: false

  alias Engram.FileTime
  alias Engram.Notes

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put(ctx, path, times, content \\ "x\n") do
    attrs = Map.merge(%{"path" => path, "content" => content}, times)
    Notes.upsert_note(ctx.user, ctx.vault, attrs, actor: "api")
  end

  defp row(ctx, id) do
    Repo.with_tenant!(ctx.user.id, fn -> Engram.Fixtures.raw_note!(id) end)
  end

  # Every row of the vault, live, tombstoned and folder markers alike.
  defp vault_rows(ctx) do
    %{rows: [[rows]]} =
      Repo.query!("SELECT count(*) FROM notes WHERE vault_id = $1", [
        Ecto.UUID.dump!(ctx.vault.id)
      ])

    assert rows > 0
    rows
  end

  defp served(ctx, path) do
    {:ok, note} = Notes.get_note(ctx.user, ctx.vault, path)
    {FileTime.mtime(note), FileTime.ctime(note)}
  end

  test "a save stores the double as sent and the timestamp normalized", ctx do
    {:ok, s} = put(ctx, "s.md", %{"mtime" => 1_776_072_500.928, "ctime" => 1_510_897_528.861})
    {:ok, ms} = put(ctx, "ms.md", %{"mtime" => 1_776_072_500_928.0})

    s = row(ctx, s.id)
    ms = row(ctx, ms.id)
    assert s.mtime_at == ms.mtime_at
    assert s.mtime_at == ~U[2026-04-13 09:28:20.928000Z]
    assert s.ctime_at == ~U[2017-11-17 05:45:28.861000Z]
  end

  test "0 is the epoch timestamp; no file time is NULL", ctx do
    {:ok, z} = put(ctx, "z.md", %{"mtime" => 0.0, "ctime" => 0.0})
    {:ok, none} = put(ctx, "n.md", %{})
    z = row(ctx, z.id)
    assert {z.mtime_at, z.ctime_at} == {~U[1970-01-01 00:00:00.000000Z], nil}
    assert row(ctx, none.id).mtime_at == nil
  end

  # Behind the client boundary (REST refuses it with a 422) a stored legacy
  # value is copied, never refused: the timestamp is NULL.
  test "an out-of-range file time past the boundary saves with a NULL timestamp", ctx do
    {:ok, n} = put(ctx, "big.md", %{"mtime" => 1.0e19, "ctime" => 1.0e19})
    n = row(ctx, n.id)
    assert {n.mtime_at, n.ctime_at} == {nil, nil}
  end

  test "the ctime batch writes ctime_at, normalized", ctx do
    {:ok, a} = put(ctx, "a.md", %{"mtime" => 1.0})
    {:ok, b} = put(ctx, "b.md", %{"mtime" => 1.0})

    {:ok, 2} =
      Notes.set_client_ctimes(ctx.user, ctx.vault, [
        %{path: "a.md", ctime: 1_510_897_528.861},
        %{path: "b.md", ctime: 1_510_897_528_861.0}
      ])

    assert row(ctx, a.id).ctime_at == ~U[2017-11-17 05:45:28.861000Z]
    assert row(ctx, b.id).ctime_at == ~U[2017-11-17 05:45:28.861000Z]
    vault_rows(ctx)
  end

  test "rename, folder rename and edit keep the timestamps, and keep them", ctx do
    {:ok, _} = put(ctx, "F/a.md", %{"mtime" => 1_776_072_500_928.0, "ctime" => 1_510_897_528.0})
    {:ok, _} = put(ctx, "F/b.md", %{"mtime" => 1_776_072_500.5})

    {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "F/b.md", "F/c.md")
    {:ok, _} = Notes.rename_folder(ctx.user, ctx.vault, "F", "G")

    assert {{:ok, _}, _} =
             Notes.rmw_note(ctx.user, ctx.vault, "G/a.md", &(&1 <> "y"), actor: "api")

    # Live notes, rename tombstones and folder markers.
    assert vault_rows(ctx) >= 5
    assert served(ctx, "G/a.md") === {1_776_072_500.928, 1_510_897_528.0}
    assert served(ctx, "G/c.md") === {1_776_072_500.5, nil}
  end

  test "delete and restore keep the timestamps, and keep them", ctx do
    {:ok, _} = put(ctx, "D/a.md", %{"mtime" => 1_776_072_500_928.0, "ctime" => 1_510_897_528.0})
    op = Ecto.UUID.generate()
    {:ok, _} = Engram.Folders.delete(ctx.user, ctx.vault, "D", recursive: true, op_id: op)

    {:ok, plan} =
      Notes.plan_restore(ctx.user, ctx.vault, op, DateTime.add(DateTime.utc_now(), -1, :day))

    {:ok, %{restored: [_]}} = Notes.restore_notes(ctx.user, ctx.vault, op, plan.notes)
    vault_rows(ctx)
    assert served(ctx, "D/a.md") === {1_776_072_500.928, 1_510_897_528.0}
  end
end
