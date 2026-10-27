defmodule Engram.Folders.RowsConcurrencyTest do
  @moduledoc """
  Two writers creating the same new folder at once, on REAL connections (see
  `Engram.CheckpointInterleave`; in the sandbox every process shares one
  connection and nothing ever blocks). The loser must neither crash nor leave
  a duplicate: the insert is `ON CONFLICT DO NOTHING`, so the transaction is
  never aborted (no 25P02) and it reads the winner's row.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Engram.Factory

  alias Engram.CheckpointInterleave
  alias Engram.Folders.{Folder, Rows}
  alias Engram.Repo

  setup do
    CheckpointInterleave.checkout_real!()
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user,
        id: user_id,
        email: "rows-race-#{System.unique_integer([:positive])}@test.com"
      )

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "RowsRace", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "two creators of one new chain agree on the ids and leave one row each", %{
    user: user,
    vault: vault
  } do
    test = self()

    first =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.with_tenant(user.id, fn ->
          {:ok, id} = Rows.ensure(user, vault.id, "Race/Inner")
          send(test, {:first_created, id})

          receive do
            :commit -> id
          after
            10_000 -> Repo.rollback(:test_timeout)
          end
        end)
      end)

    assert_receive {:first_created, _}, 5_000

    second =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.with_tenant(user.id, fn ->
          {:ok, id} = Rows.ensure(user, vault.id, "Race/Inner")
          send(test, {:second_done, id})
          id
        end)
      end)

    # The second creator waits on the first one's uncommitted unique entry.
    refute_receive {:second_done, _}, 300
    send(first.pid, :commit)

    assert {:ok, a} = Task.await(first)
    assert {:ok, b} = Task.await(second)
    assert a == b

    {:ok, count} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(f in Folder, where: f.vault_id == ^vault.id), :count)
      end)

    assert count == 2
  end
end
