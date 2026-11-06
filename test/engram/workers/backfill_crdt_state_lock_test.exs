defmodule Engram.Workers.BackfillCrdtStateLockTest do
  @moduledoc """
  The seed UPDATE's fence must hold across a row-lock wait.

  `BackfillCrdtState.write_seed/3` seeds a note only while it still has no
  CRDT state. A checkpoint that commits while the seed waits on the notes
  row lock gives the note state; the seed must then write nothing. In READ
  COMMITTED the waiting UPDATE re-checks its WHERE on the newest notes row
  (EvalPlanQual), but a subquery on `note_bodies` there still sees the body
  as the statement first read it: NULL. So a fence on the body would pass
  and overwrite the checkpoint. The fence reads the locked row's
  `crdt_state_nonce` instead (`Engram.Notes.NoteBody` moduledoc).

  Two real sessions: the sandbox shares one transaction across processes,
  so everything is created through `unboxed_run` and deleted afterwards
  (as `Engram.Notes.LockedReadBodyTest`).
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Engram.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Notes, Repo, Vaults}
  alias Engram.Notes.{Note, NoteBody}
  alias Engram.Workers.BackfillCrdtState

  setup do
    Sandbox.unboxed_run(Repo, fn ->
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      {:ok, vault, _} = Vaults.register_vault(user, "SeedLock", Ecto.UUID.generate())

      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "# S\n"}, actor: "api")

      # A seedable note: no CRDT state in either copy, no tail.
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id == ^note.id),
            set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
          )

          Repo.delete_all(from(l in Engram.Notes.CrdtUpdateLog, where: l.note_id == ^note.id))

          NoteBody.put!({note.id, crdt_state_ciphertext: nil, crdt_state_nonce: nil})
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          id = Ecto.UUID.dump!(user.id)
          Repo.query!("DELETE FROM oban_jobs WHERE args->>'user_id' = $1", [user.id])

          for table <- ~w(note_revisions crdt_update_log notes vaults) do
            Repo.query!("DELETE FROM #{table} WHERE user_id = $1", [id])
          end

          Repo.query!("DELETE FROM users WHERE id = $1", [id])
        end)
      end)

      %{user: user, note: note}
    end)
  end

  # Waits until the seeder's own backend is blocked on a lock.
  defp await_lock_wait(pid, tries \\ 150)
  defp await_lock_wait(_pid, 0), do: flunk("the seed never waited on the row lock")

  defp await_lock_wait(pid, tries) do
    %{rows: [[n]]} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock'",
          [pid]
        )
      end)

    if n > 0, do: :ok, else: Process.sleep(20) && await_lock_wait(pid, tries - 1)
  end

  test "a checkpoint committed during the seed's lock wait is not overwritten", ctx do
    nonce = <<1>> <> :crypto.strong_rand_bytes(12)
    ct = :crypto.strong_rand_bytes(40)
    parent = self()

    assert Sandbox.unboxed_run(Repo, fn ->
             {:ok, any} =
               Repo.with_tenant(ctx.user.id, fn ->
                 Repo.exists?(where(BackfillCrdtState.seedable(), [n], n.id == ^ctx.note.id))
               end)

             any
           end),
           "precondition: the note is seedable"

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            # A checkpoint: the first snapshot, both copies, one transaction.
            Repo.query!(
              "UPDATE notes SET crdt_state_ciphertext = $2, crdt_state_nonce = $3 WHERE id = $1",
              [Ecto.UUID.dump!(ctx.note.id), ct, nonce]
            )

            NoteBody.sync!(ctx.note.id, [:crdt_state_ciphertext])

            send(parent, :locked)
            receive do: (:commit -> :ok)
          end)
        end)
      end)

    assert_receive :locked, 5_000

    seeder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:seeder_pid, pid})

          Repo.with_tenant(ctx.user.id, fn ->
            BackfillCrdtState.write_seed(ctx.note.id, <<9, 9, 9>>, <<8, 8, 8>>)
          end)
        end)
      end)

    assert_receive {:seeder_pid, seeder_pid}, 5_000
    await_lock_wait(seeder_pid)
    send(holder.pid, :commit)
    Task.await(holder, 10_000)

    assert {:ok, 0} = Task.await(seeder, 10_000)

    %{rows: [[notes_nonce, body]]} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "SELECT n.crdt_state_nonce, b.crdt_ct FROM notes n JOIN note_bodies b ON b.note_id = n.id WHERE n.id = $1",
          [Ecto.UUID.dump!(ctx.note.id)]
        )
      end)

    assert notes_nonce == nonce
    assert body == nonce <> ct
  end
end
