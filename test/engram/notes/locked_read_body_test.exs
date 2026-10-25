defmodule Engram.Notes.LockedReadBodyTest do
  @moduledoc """
  A row-locked read that WAITED must see the body the lock holder committed.

  In READ COMMITTED, a `SELECT ... FOR UPDATE OF n0` that waits on the notes
  row re-fetches only the locked relation at its newest version
  (EvalPlanQual); every joined relation (a LEFT JOINed `note_bodies`) comes
  back as the statement first read it. So a locked read that joins the body
  pairs a fresh notes row with a stale body, and the write behind it loses
  its snapshot fence every time it actually waited. Locked reads therefore
  take the body from the `notes` columns, which this release still writes
  in step (`Engram.Notes.NoteBody` moduledoc).

  Two real sessions: the sandbox shares one transaction across processes,
  so everything is created through `unboxed_run` and deleted afterwards.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Notes, Repo, Vaults}

  setup do
    Sandbox.unboxed_run(Repo, fn ->
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      {:ok, vault, _} = Vaults.register_vault(user, "Locked", Ecto.UUID.generate())

      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "L.md", "content" => "# L\n"}, actor: "api")

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          id = Ecto.UUID.dump!(user.id)
          # The write committed for real, and so did its jobs: a later test
          # asserting nothing is enqueued would see them.
          Repo.query!("DELETE FROM oban_jobs WHERE args->>'user_id' = $1", [user.id])

          for table <- ~w(note_revisions crdt_update_log notes vaults) do
            Repo.query!("DELETE FROM #{table} WHERE user_id = $1", [id])
          end

          Repo.query!("DELETE FROM users WHERE id = $1", [id])
        end)
      end)

      %{user: user, vault: vault, note: note}
    end)
  end

  defp await_lock_wait(tries \\ 150)
  defp await_lock_wait(0), do: flunk("the locked read never waited on the row lock")

  defp await_lock_wait(tries) do
    %{rows: [[n]]} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock'")
      end)

    if n > 0, do: :ok, else: Process.sleep(20) && await_lock_wait(tries - 1)
  end

  test "get_note_for_update after a wait returns the committed CRDT state", ctx do
    nonce = <<1>> <> :crypto.strong_rand_bytes(12)
    ct = :crypto.strong_rand_bytes(40)
    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            # A checkpoint-shaped write: a new snapshot under a new nonce.
            Repo.query!(
              "UPDATE notes SET crdt_state_ciphertext = $2, crdt_state_nonce = $3 WHERE id = $1",
              [Ecto.UUID.dump!(ctx.note.id), ct, nonce]
            )

            send(parent, :locked)
            receive do: (:commit -> :ok)
          end)
        end)
      end)

    assert_receive :locked, 5_000

    reader =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.with_tenant(ctx.user.id, fn ->
            Notes.get_note_for_update(ctx.user, ctx.vault, "L.md")
          end)
        end)
      end)

    await_lock_wait()
    send(holder.pid, :commit)
    Task.await(holder, 10_000)

    assert {:ok, {:ok, note}} = Task.await(reader, 10_000)
    assert note.crdt_state_nonce == nonce
    assert note.crdt_state_ciphertext == ct
  end
end
