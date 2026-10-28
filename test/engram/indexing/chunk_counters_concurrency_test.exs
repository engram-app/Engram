defmodule Engram.Indexing.ChunkCountersConcurrencyTest do
  @moduledoc """
  Two transactions writing chunks of the SAME note at once, on REAL
  connections (`Engram.CheckpointInterleave`; in the sandbox every process
  shares one connection, so nothing ever waits). Neither holds the note
  lock, so only the chunk trigger orders them.

  The trigger locks the note's state row, then counts in a NEW statement:
  the second writer waits for the first to commit, and its count sees the
  first one's rows. Counted inside the first statement's snapshot instead,
  the second writer would write a count missing the first one's chunks
  (the same result as the old `ChunkRows.recount!/2` under its note lock).
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Engram.CheckpointInterleave
  alias Engram.Notes
  alias Engram.Repo

  setup do
    CheckpointInterleave.checkout_real!()

    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user,
        id: user_id,
        email: "chunk-race-#{System.unique_integer([:positive])}@test.com"
      )

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "ChunkRace", Ecto.UUID.generate())

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "x"}, actor: "api")

    %{user: user, note: note}
  end

  defp insert_sql(note, positions, tokens) do
    {"""
     INSERT INTO chunks (note_id, user_id, vault_id, position, char_start, char_end,
                         token_count, qdrant_point_id)
     SELECT $1, $2, $3, p, 0, 1, $4, gen_random_uuid() FROM unnest($5::int4[]) p
     """,
     [
       Ecto.UUID.dump!(note.id),
       Ecto.UUID.dump!(note.user_id),
       Ecto.UUID.dump!(note.vault_id),
       tokens,
       positions
     ]}
  end

  test "concurrent chunk statements on one note end exact", %{user: user, note: note} do
    test = self()

    first =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.with_tenant(user.id, fn ->
          {sql, params} = insert_sql(note, Enum.to_list(0..4), 10)
          Repo.query!(sql, params)
          send(test, :first_wrote)

          receive do
            :commit -> :ok
          after
            15_000 -> Repo.rollback(:test_timeout)
          end
        end)
      end)

    assert_receive :first_wrote, 5_000

    second =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.with_tenant(user.id, fn ->
          {sql, params} = insert_sql(note, Enum.to_list(5..7), 1)
          # Blocks on the state row the first writer's trigger holds.
          Repo.query!(sql, params)
        end)
      end)

    # Let the second writer reach the lock, then release the first.
    Process.sleep(200)
    send(first.pid, :commit)
    assert {:ok, _} = Task.await(first)
    assert {:ok, _} = Task.await(second)

    {:ok, %{rows: [[p, lr, ls]]}} =
      Repo.with_tenant(user.id, fn ->
        Repo.query!(
          "SELECT points, len_rows, len_sum FROM note_index_state WHERE note_id = $1",
          [Ecto.UUID.dump!(note.id)]
        )
      end)

    assert {p, lr, ls} == {8, 8, 53}
  end
end
