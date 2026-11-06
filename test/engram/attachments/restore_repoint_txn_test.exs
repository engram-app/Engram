defmodule Engram.Attachments.RestoreRepointTxnTest do
  # #2469: an attachment restore revived the row and re-pointed its
  # `folder_ref_id` in two transactions. A crash between them left a live row
  # naming a dead folder row under a stamp that still read current, which no
  # drift index sees, so nothing healed it. Revive and re-point now share one
  # tenant transaction.
  #
  # Every write runs as the prod-like `engram_app` (no SUPERUSER, no
  # BYPASSRLS) under FORCE RLS, through `Engram.RlsCase`: the suite's
  # superuser would see every row whatever the tenant
  # (docs/context/rls-enforcement-testing-traps.md).
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.{Attachments, Folders, Notes, Repo}
  alias Engram.FolderRows
  alias Engram.QueryRecorder

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "P/a.png",
        "content_base64" => Base.encode64("bytes")
      })

    dead_ref = FolderRows.ref("attachments", att.id)
    op = Ecto.UUID.generate()
    assert {:ok, _} = Folders.delete(user, vault, "P", recursive: true, op_id: op)

    # A live sibling takes the name, so the undo cannot revive the folder row
    # the attachment still names: the restore has to re-point it.
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "P/new.md", "content" => "# T"}, actor: "api")

    live_ref = FolderRows.ref("notes", note.id)
    assert dead_ref && live_ref && dead_ref != live_ref

    %{user: user, vault: vault, att: att, op: op, dead_ref: dead_ref, live_ref: live_ref}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp row(att_id) do
    %{rows: [[deleted_at, ref, stamp, nonce]]} =
      Repo.query!(
        "SELECT deleted_at, folder_ref_id, folder_ref_stamp, path_nonce FROM attachments WHERE id = $1",
        [dump(att_id)]
      )

    %{
      deleted?: not is_nil(deleted_at),
      ref: ref && Ecto.UUID.load!(ref),
      current?: stamp == nonce
    }
  end

  # The crash: any statement that moves a live attachment's reference raises,
  # standing in for the process dying between the revive and the re-point.
  defp fail_repoint! do
    Repo.query!("""
    CREATE FUNCTION pg_temp.fail_repoint() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'crash before re-point'; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER fail_repoint BEFORE UPDATE OF folder_ref_id ON attachments
      FOR EACH ROW
      WHEN (OLD.deleted_at IS NULL AND NEW.folder_ref_id IS DISTINCT FROM OLD.folder_ref_id)
      EXECUTE FUNCTION pg_temp.fail_repoint()
    """)
  end

  # Red on main: the revive had committed, so the row came back live with the
  # dead reference and a current stamp. One transaction: the revive rolls back
  # with the re-point.
  test "a crash before the re-point leaves no live row trusting a dead reference", ctx do
    fail_repoint!()

    as_prod_role_raising(fn ->
      assert_raise Postgrex.Error, ~r/crash before re-point/, fn ->
        Folders.restore_op(ctx.user, ctx.vault, ctx.op)
      end
    end)

    assert %{deleted?: true} = row(ctx.att.id)
  end

  test "a restore revives the row pointing at the live folder, stamp current", ctx do
    as_prod_role_committing(fn ->
      assert {:ok, %{attachments: 1}} = Folders.restore_op(ctx.user, ctx.vault, ctx.op)
    end)

    assert row(ctx.att.id) == %{deleted?: false, ref: ctx.live_ref, current?: true}
  end

  # The re-point runs under the vault lock every writer of the vault waits on:
  # its statement count must not grow with the folders a chunk spans. Red on
  # 61be8aaaf, which sent one UPDATE per folder.
  test "a chunk spread over many folders is re-pointed in one statement", %{user: u, vault: v} do
    atts =
      for i <- 1..50 do
        {:ok, a} =
          Attachments.upsert_attachment(u, v, %{
            "path" => "Many/f#{i}/a.png",
            "content_base64" => Base.encode64("bytes #{i}")
          })

        {"Many/f#{i}", a}
      end

    op = Ecto.UUID.generate()
    assert {:ok, _} = Folders.delete(u, v, "Many", recursive: true, op_id: op)

    {_, queries} =
      QueryRecorder.record(fn ->
        as_prod_role_committing(fn ->
          assert {:ok, %{attachments: 50}} = Folders.restore_op(u, v, op)
        end)
      end)

    repoints =
      for %{sql: sql, pid: pid} <- queries,
          pid == self(),
          sql =~ ~r/^\s*(WITH .*)?UPDATE "?attachments"?.*\bSET\b.*"?folder_ref_id"?\s*=/s,
          do: sql

    assert length(repoints) == 1, Enum.join(repoints, "\n")

    tree = FolderRows.tree(u)

    for {folder, a} <- atts do
      assert row(a.id) == %{deleted?: false, ref: tree[folder].id, current?: true}
    end
  end

  test "a revive without a re-point clears the stamp, so the drain sees it", ctx do
    as_prod_role_committing(fn ->
      assert {:ok, %{restored: [_]}} =
               Attachments.revive_tombstones(ctx.user, ctx.vault, [ctx.att.id], [])
    end)

    assert %{deleted?: false, ref: ref, current?: false} = row(ctx.att.id)
    assert ref == ctx.dead_ref
  end

  test "control: engram_app with no tenant sees zero attachments", %{att: att} do
    count = fn ->
      Repo.query!("SELECT count(*)::int FROM attachments WHERE id = $1", [dump(att.id)])
    end

    # The row is there; only the role drop hides it.
    assert %{rows: [[1]]} = count.()
    as_prod_role_committing(fn -> assert %{rows: [[0]]} = count.() end)
  end
end
