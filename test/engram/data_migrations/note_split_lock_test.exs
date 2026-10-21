defmodule Engram.DataMigrations.NoteSplitLockTest do
  @moduledoc """
  NoteSplit's SKIP LOCKED path, on REAL connections (see
  `Engram.CheckpointInterleave`): in the sandbox every process shares one
  connection, so a row lock never blocks and SKIP LOCKED never skips.

  A pass that skipped a row a writer held touched nothing, but the row still
  needs work. Reporting `:done` there closes the ledger and turns the id
  lookups on while a row has no ids.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Engram.CheckpointInterleave
  alias Engram.DataMigrations.NoteSplit
  alias Engram.Notes
  alias Engram.Repo

  setup do
    CheckpointInterleave.checkout_real!()

    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user,
        id: user_id,
        email: "split-lock-#{System.unique_integer([:positive])}@test.com"
      )

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "SplitLock", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "a row a writer holds keeps the pass open", %{user: user, vault: vault} do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "l.md", "content" => "x"}, actor: "api")

    id = Ecto.UUID.dump!(note.id)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.query!("DELETE FROM note_bodies WHERE note_id = $1", [id])
      end)

    test = self()

    holder =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.with_tenant(user.id, fn ->
          Repo.query!("SELECT id FROM notes WHERE id = $1 FOR UPDATE", [id])
          send(test, :locked)

          receive do
            :release -> :ok
          after
            15_000 -> Repo.rollback(:test_timeout)
          end
        end)
      end)

    assert_receive :locked, 5_000

    # Skipped, not fixed: the pass must not report done.
    refute NoteSplit.run_pass() == :done

    send(holder.pid, :release)
    Task.await(holder)

    assert {:more, _} = NoteSplit.run_pass()

    # Inside the tenant: note_bodies is under FORCE ROW LEVEL SECURITY.
    assert {:ok, %{rows: [[true]]}} =
             Repo.with_tenant(user.id, fn ->
               Repo.query!("SELECT count(*) > 0 FROM note_bodies WHERE note_id = $1", [id])
             end)
  end
end
