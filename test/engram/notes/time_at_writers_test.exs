defmodule Engram.Notes.TimeAtWritersTest do
  @moduledoc """
  Every writer of `notes.mtime` / `notes.ctime` also writes `mtime_at` /
  `ctime_at` (`Engram.FileTime`): the doubles are stored as sent, the
  timestamps normalized. A copy (rename, restore, edit, tombstone, folder
  marker) keeps the two in step: `*_at == FileTime.to_at(double)` on every
  row of the vault.
  """
  use Engram.DataCase, async: false

  alias Engram.FileTime
  alias Engram.Notes
  alias Engram.Notes.Note

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
  defp assert_parity!(ctx) do
    rows =
      Repo.with_tenant!(ctx.user.id, fn ->
        Repo.all(
          from(n in Note,
            where: n.vault_id == ^ctx.vault.id,
            select: {n.kind, n.deleted_at, n.mtime, n.mtime_at, n.ctime, n.ctime_at}
          )
        )
      end)

    assert rows != []

    for {kind, deleted, mtime, mtime_at, ctime, ctime_at} <- rows do
      label = inspect({kind, deleted, mtime, ctime})
      assert {:ok, mtime_at} == FileTime.to_at(mtime), label
      assert {:ok, ctime_at} == FileTime.to_at(ctime), label
    end

    length(rows)
  end

  test "a save stores the double as sent and the timestamp normalized", ctx do
    {:ok, s} = put(ctx, "s.md", %{"mtime" => 1_776_072_500.928, "ctime" => 1_510_897_528.861})
    {:ok, ms} = put(ctx, "ms.md", %{"mtime" => 1_776_072_500_928.0})

    s = row(ctx, s.id)
    ms = row(ctx, ms.id)
    assert ms.mtime == 1_776_072_500_928.0
    assert s.mtime_at == ms.mtime_at
    assert s.mtime_at == ~U[2026-04-13 09:28:20.928000Z]
    assert s.ctime_at == ~U[2017-11-17 05:45:28.861000Z]
  end

  test "0 and no file time are NULL timestamps", ctx do
    {:ok, z} = put(ctx, "z.md", %{"mtime" => 0.0, "ctime" => 0.0})
    {:ok, none} = put(ctx, "n.md", %{})
    assert {row(ctx, z.id).mtime_at, row(ctx, none.id).mtime_at} == {nil, nil}
  end

  # Behind the client boundary (REST refuses it with a 422) a stored legacy
  # value is copied, never refused: the timestamp is NULL.
  test "an out-of-range file time past the boundary saves with a NULL timestamp", ctx do
    {:ok, n} = put(ctx, "big.md", %{"mtime" => 1.0e19, "ctime" => 1.0e19})
    n = row(ctx, n.id)
    assert {n.mtime, n.mtime_at, n.ctime_at} == {1.0e19, nil, nil}
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
    assert row(ctx, b.id).ctime == 1_510_897_528_861.0
  end

  # A pre-expand writer moved the double alone; the next write that carries
  # the same double (a re-push, an edit, a move) heals the twin.
  test "a write carrying an unchanged double heals a stale twin", ctx do
    {:ok, n} = put(ctx, "h.md", %{"mtime" => 1_776_072_500.5, "ctime" => 1_510_897_528.0})

    Repo.with_tenant!(ctx.user.id, fn ->
      Repo.update_all(from(x in Note, where: x.id == ^n.id),
        set: [mtime_at: ~U[2000-01-01 00:00:00.000000Z], ctime_at: nil]
      )
    end)

    {:ok, _} = put(ctx, "h.md", %{"mtime" => 1_776_072_500.5}, "y\n")
    n = row(ctx, n.id)
    assert n.mtime_at == FileTime.to_at!(1_776_072_500.5)
    assert n.ctime_at == FileTime.to_at!(1_510_897_528.0)
  end

  test "rename, folder rename and edit keep the timestamps with the doubles", ctx do
    {:ok, _} = put(ctx, "F/a.md", %{"mtime" => 1_776_072_500_928.0, "ctime" => 1_510_897_528.0})
    {:ok, _} = put(ctx, "F/b.md", %{"mtime" => 1_776_072_500.5})

    {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "F/b.md", "F/c.md")
    {:ok, _} = Notes.rename_folder(ctx.user, ctx.vault, "F", "G")

    assert {{:ok, _}, _} =
             Notes.rmw_note(ctx.user, ctx.vault, "G/a.md", &(&1 <> "y"), actor: "api")

    # Live notes, rename tombstones and folder markers.
    assert assert_parity!(ctx) >= 5
  end

  test "delete and restore keep the timestamps with the doubles", ctx do
    {:ok, _} = put(ctx, "D/a.md", %{"mtime" => 1_776_072_500_928.0, "ctime" => 1_510_897_528.0})
    op = Ecto.UUID.generate()
    {:ok, _} = Engram.Folders.delete(ctx.user, ctx.vault, "D", recursive: true, op_id: op)

    {:ok, plan} =
      Notes.plan_restore(ctx.user, ctx.vault, op, DateTime.add(DateTime.utc_now(), -1, :day))

    {:ok, %{restored: [_]}} = Notes.restore_notes(ctx.user, ctx.vault, op, plan.notes)
    assert_parity!(ctx)
  end
end
