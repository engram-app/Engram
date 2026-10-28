defmodule Engram.DataMigrations.NoteIndexStateLockTest do
  @moduledoc """
  NoteIndexState's SKIP LOCKED path, on REAL connections (see
  `Engram.CheckpointInterleave`): in the sandbox every process shares one
  connection, so a row lock never blocks and SKIP LOCKED never skips.

  A drifted note a writer holds is skipped, not recounted. The walk is the
  only completion check (#2276), so that skip must keep the pass open, or
  the ledger closes with wrong counters and the vault sums read them.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Engram.CheckpointInterleave
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteIndexState
  alias Engram.Notes
  alias Engram.Repo

  setup do
    CheckpointInterleave.checkout_real!()
    DataMigrations.reset_cache()

    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user,
        id: user_id,
        email: "index-state-lock-#{System.unique_integer([:positive])}@test.com"
      )

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "IndexLock", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp points(user_id, id) do
    {:ok, %{rows: [[p]]}} =
      Repo.with_tenant(user_id, fn ->
        Repo.query!("SELECT points FROM note_index_state WHERE note_id = $1", [id])
      end)

    p
  end

  test "a drifted note a writer holds keeps the pass open", %{user: user, vault: vault} do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "l.md", "content" => "x"}, actor: "api")

    id = Ecto.UUID.dump!(note.id)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.query!("UPDATE note_index_state SET points = 99 WHERE note_id = $1", [id])
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
    refute NoteIndexState.run_pass() == :done
    assert points(user.id, id) == 99

    send(holder.pid, :release)
    Task.await(holder)

    assert {:more, _} = NoteIndexState.run_pass()
    assert points(user.id, id) == 0
    assert :done = NoteIndexState.run_pass()
  end
end
