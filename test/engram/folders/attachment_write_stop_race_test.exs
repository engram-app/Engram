defmodule Engram.Folders.AttachmentWriteStopRaceTest do
  @moduledoc """
  S6 step 6 phase 2 (Engram#2523): `Folders.rename/5` decides whether the
  attachments stay in place (`att_keyed?`, every attachment under the folder
  has a `name_key`) from a scan BEFORE its transaction. An attachment write
  that commits between that scan and the transaction must not leave a row
  the move orphans (one read at its stored path under a folder that is gone).

  On REAL connections (see `Engram.CheckpointInterleave`): the test holds the
  vault's folder-write lock, so the rename scans, then waits at the lock;
  a restore and an upload under the folder commit in that window; then the
  rename runs.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Engram.{Attachments, CheckpointInterleave, Folders, Notes, Repo, ServiceConfig, Vaults}

  setup do
    CheckpointInterleave.checkout_real!()
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    ServiceConfig.put_override(:folder_ops, true)
    ServiceConfig.put_override(:attachment_name_key_ledger, :done)

    user =
      insert(:user, id: user_id, email: "att-stop-#{System.unique_integer([:positive])}@t.com")

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "AttStop", Ecto.UUID.generate())

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "A/n.md", "content" => "n"}, actor: "api")

    for path <- ["A/x.png", "A/t.png"], do: put!(user, vault, path)
    op = Ecto.UUID.generate()
    {:ok, %{deleted: 1}} = Attachments.batch_delete(user, vault, ["A/t.png"], op_id: op)
    %{user: user, vault: vault, op: op}
  end

  defp put!(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes of " <> path)
      })

    att
  end

  defp await_lock_wait(tries \\ 100)
  defp await_lock_wait(0), do: flunk("the rename never waited on the folder-write lock")

  defp await_lock_wait(tries) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    if n > 0, do: :ok, else: Process.sleep(50) && await_lock_wait(tries - 1)
  end

  test "a restore and an upload between the rename's scan and its transaction",
       %{user: u, vault: v, op: op} do
    assert Attachments.WriteStop.on?()
    test = self()

    holder =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.transaction(fn ->
          :ok = Vaults.lock_folder_writes!(v.id)
          send(test, :held)
          receive do: (:release -> :ok), after: (15_000 -> Repo.rollback(:test_timeout))
        end)
      end)

    assert_receive :held, 5_000

    rename =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()
        Folders.rename(u, v, "A", "B")
      end)

    await_lock_wait()

    # In the window: both commit while the rename waits.
    {:ok, %{attachments: metas}} =
      Attachments.plan_restore(u, v, op, DateTime.add(DateTime.utc_now(), -1, :day))

    assert {:ok, %{restored: ["A/t.png"]}} = Attachments.restore_attachments(u, v, metas)
    _ = put!(u, v, "A/u.png")

    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, 15_000)
    assert {:ok, %{notes: 1}} = Task.await(rename, 15_000)

    # Every file under the folder is read, and listed, under its new name.
    {:ok, listed} = Attachments.list_attachments(u, v)
    assert listed |> Enum.map(& &1.path) |> Enum.sort() == ["B/t.png", "B/u.png", "B/x.png"]

    for name <- ["t.png", "u.png", "x.png"] do
      assert {:ok, %{path: "B/" <> ^name}} = Attachments.get_attachment(u, v, "B/" <> name)
      assert {:ok, nil} = Attachments.get_attachment(u, v, "A/" <> name)
    end
  end
end
