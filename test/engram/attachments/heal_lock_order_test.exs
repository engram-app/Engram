defmodule Engram.Attachments.HealLockOrderTest do
  @moduledoc """
  Review B1 of #2647 (the #2339 order): a write at the shown path of a stale
  attachment heals it (`Attachments.settle/3`) only under the vault row lock
  (`Vaults.lock_seq!/1`), the lock every writer and a cascading folder rename
  take before any attachment row. A heal that repointed first and took the
  vault lock after was the reverse order (a 40P01 deadlock against a
  cascade), and let a folder move between the heal and the write.

  On REAL connections (see `Engram.CheckpointInterleave`): the test holds the
  vault row; a write at the shown path must wait for it with the stale row
  untouched, then heal and land once it is released.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Engram.{Attachments, CheckpointInterleave, Crypto, Notes, Repo, Vaults}

  setup do
    CheckpointInterleave.checkout_real!()
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user, id: user_id, email: "heal-lock-#{System.unique_integer([:positive])}@t.com")

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "HealLock", Ecto.UUID.generate())

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "A/n.md", "content" => "n"}, actor: "api")

    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "A/x.png",
        "content_base64" => Base.encode64("old bytes")
      })

    {:ok, {:ok, 1}} =
      Repo.with_tenant(user.id, fn -> Notes.rename_folder_uncascaded(user, vault, "A", "B") end)

    %{user: user, vault: vault, att: att}
  end

  defp stored_hmac(user, id) do
    {:ok, %{rows: [[h]]}} =
      Repo.with_tenant(user.id, fn ->
        Repo.query!("SELECT path_hmac FROM attachments WHERE id = $1", [Ecto.UUID.dump!(id)])
      end)

    h
  end

  defp await_lock_wait(tries \\ 100)
  defp await_lock_wait(0), do: flunk("the write never waited on the vault row")

  defp await_lock_wait(tries) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    if n > 0, do: :ok, else: Process.sleep(50) && await_lock_wait(tries - 1)
  end

  test "the heal waits for the vault row before it touches the stale row",
       %{user: u, vault: v, att: att} do
    {:ok, fk} = Crypto.dek_filter_key(u)
    stale = Crypto.hmac_field(fk, "A/x.png")
    assert stored_hmac(u, att.id) == stale
    test = self()

    holder =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.with_tenant(u.id, fn ->
          :ok = Vaults.lock_seq!(v.id)
          send(test, :held)
          receive do: (:release -> :ok), after: (15_000 -> Repo.rollback(:test_timeout))
        end)
      end)

    assert_receive :held, 5_000

    write =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Attachments.upsert_attachment(u, v, %{
          "path" => "B/x.png",
          "content_base64" => Base.encode64("new bytes")
        })
      end)

    await_lock_wait()
    # Waiting, and nothing healed yet: the stale row is as it was, and no
    # other transaction holds it.
    assert stored_hmac(u, att.id) == stale

    {:ok, _} =
      Repo.with_tenant(u.id, fn ->
        Repo.query!("SELECT id FROM attachments WHERE id = $1 FOR UPDATE NOWAIT", [
          Ecto.UUID.dump!(att.id)
        ])
      end)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 15_000)
    assert {:ok, %{id: id}} = Task.await(write, 15_000)
    assert id == att.id
    assert stored_hmac(u, att.id) == Crypto.hmac_field(fk, "B/x.png")
    assert {:ok, %{content: "new bytes"}} = Attachments.get_attachment(u, v, "B/x.png")
  end
end
