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

  # `engram_app` for code that RAISES out of its own transactions. Neither
  # `Engram.RlsCase` helper fits: a raise out of a nested transaction marks
  # their enclosing one as rolling back, discarding the very commits under
  # test. Here the restore's transactions are the outermost the app opens (the
  # sandbox makes them savepoints), so a raise rolls back only its own.
  defp as_app_raising(fun) do
    Repo.query!("SELECT set_config('app.current_tenant', '', false)")
    Repo.query!("SET SESSION AUTHORIZATION engram_app")

    try do
      fun.()
    after
      Repo.query!("RESET SESSION AUTHORIZATION")
    end
  end

  # Red on main: the revive had committed, so the row came back live with the
  # dead reference and a current stamp.
  test "a crash before the re-point leaves no live row trusting a dead reference", ctx do
    fail_repoint!()

    as_app_raising(fn ->
      assert_raise Postgrex.Error, ~r/crash before re-point/, fn ->
        Folders.restore_op(ctx.user, ctx.vault, ctx.op)
      end
    end)

    r = row(ctx.att.id)
    assert r.deleted? or r.ref == ctx.live_ref or not r.current?, inspect(r)
    # One transaction: the revive rolled back with the re-point.
    assert r.deleted?
  end

  test "a restore revives the row pointing at the live folder, stamp current", ctx do
    as_prod_role_committing(fn ->
      assert {:ok, %{attachments: 1}} = Folders.restore_op(ctx.user, ctx.vault, ctx.op)
    end)

    assert row(ctx.att.id) == %{deleted?: false, ref: ctx.live_ref, current?: true}
  end

  test "a revive without a re-point clears the stamp, so the drain sees it", ctx do
    as_prod_role_committing(fn ->
      assert {:ok, %{restored: [_]}} =
               Attachments.revive_tombstones(ctx.user, ctx.vault, [ctx.att.id])
    end)

    assert %{deleted?: false, ref: ref, current?: false} = row(ctx.att.id)
    assert ref == ctx.dead_ref
  end

  test "control: engram_app with no tenant sees zero attachments", %{att: att} do
    as_prod_role_committing(fn ->
      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*)::int FROM attachments WHERE id = $1", [dump(att.id)])
    end)
  end
end
