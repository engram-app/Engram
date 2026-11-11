defmodule Engram.Migrations.NoteBodiesPreNonceHealRaceTest do
  @moduledoc """
  A writer sets a note's body between the heal's read and its UPDATE. The
  sandbox runs every statement on one connection, one after another, so
  this runs outside it: a writer connection holds the body row locked with
  a newer body, the heal (its own connection) reads the old snapshot and
  blocks on that row in its UPDATE, then the writer commits. Under READ
  COMMITTED the UPDATE re-reads the committed row; only the CASE guard in
  `SET` (fill a NULL body, else keep it) stops it writing the stale `notes`
  copy over the newer body. The `after` stops the writer (rolling it back
  if it never committed, so its row lock cannot block the cleanup) and the
  heal, then deletes the user, its notes and the jobs the test enqueued,
  each delete on its own.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Notes, Repo}

  require Logger

  @mod "Elixir.Engram.Repo.Migrations.NoteBodiesPreNonceHealMigrate"

  setup_all do
    Code.require_file(
      "priv/repo/migrations/20261110130000_note_bodies_pre_nonce_heal_migrate.exs"
    )

    :ok
  end

  defp content_ct(id) do
    Repo.query!("SELECT content_ct FROM note_bodies WHERE note_id = $1", [id]).rows
  end

  defp job_count, do: hd(hd(Repo.query!("SELECT count(*) FROM oban_jobs").rows))

  # Polls until a session waits on a lock inside the heal's UPDATE.
  defp await_blocked_heal(tries \\ 100) do
    %{rows: [[n]]} =
      Repo.query!("""
      SELECT count(*) FROM pg_stat_activity
      WHERE wait_event_type = 'Lock' AND query LIKE '%UPDATE note_bodies b SET%'
      """)

    cond do
      n > 0 -> :ok
      tries == 0 -> flunk("the heal never blocked on the writer's row lock")
      true -> await_blocked_heal_after_sleep(tries)
    end
  end

  defp await_blocked_heal_after_sleep(tries) do
    Process.sleep(50)
    await_blocked_heal(tries - 1)
  end

  # Tasks and rows this test makes, so `after` can stop and delete them
  # even when the test fails half way.
  defp track(key, value), do: Process.put({__MODULE__, key}, value)
  defp tracked(key), do: Process.get({__MODULE__, key})

  # The writer rolls back if it has not committed (its row lock would block
  # every delete below); the heal is given time to finish, then killed.
  defp stop_tasks do
    if writer = tracked(:writer) do
      send(writer.pid, :rollback)
      Task.yield(writer, 5_000) || Task.shutdown(writer, :brutal_kill)
    end

    if heal = tracked(:heal), do: Task.yield(heal, 15_000) || Task.shutdown(heal, :brutal_kill)
  end

  # Each delete on its own, so one failure does not skip the rest; failures
  # are logged and returned. Jobs go by note id and by the test's window
  # (vault registration enqueues some with no note id).
  defp cleanup(started) do
    user = tracked(:user)
    note = tracked(:note)

    [
      {"DELETE FROM oban_jobs WHERE inserted_at >= $1 OR args->>'note_id' = $2",
       [started, note && note.id]},
      {"DELETE FROM notes WHERE user_id = $1", [user && Ecto.UUID.dump!(user.id)]},
      {"DELETE FROM users WHERE id = $1", [user && Ecto.UUID.dump!(user.id)]}
    ]
    |> Enum.flat_map(fn {sql, params} ->
      try do
        Repo.query!(sql, params)
        []
      rescue
        e ->
          Logger.error("race test cleanup failed: #{sql}: #{Exception.message(e)}")
          [sql]
      end
    end)
  end

  defp leftovers(user_id) do
    Repo.query!(
      """
      SELECT (SELECT count(*) FROM users WHERE id = $1),
        (SELECT count(*) FROM notes WHERE user_id = $1),
        (SELECT count(*) FROM oban_jobs)
      """,
      [user_id]
    ).rows
  end

  test "a body written between the heal's read and its UPDATE is kept" do
    {jobs_before, started} =
      Sandbox.unboxed_run(Repo, fn ->
        {job_count(), hd(hd(Repo.query!("SELECT timezone('UTC', now())").rows))}
      end)

    Sandbox.unboxed_run(Repo, fn ->
      try do
        {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
        track(:user, user)
        {:ok, vault, _} = Engram.Vaults.register_vault(user, "Race", Ecto.UUID.generate())

        {:ok, note} =
          Notes.upsert_note(user, vault, %{"path" => "race.md", "content" => "old"}, actor: "api")

        track(:note, note)
        Engram.Fixtures.pre_nonce_null_body!(note.id)
        id = Ecto.UUID.dump!(note.id)
        newer = <<1>> <> :crypto.strong_rand_bytes(60)
        parent = self()

        writer =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                Repo.query!("UPDATE note_bodies SET content_ct = $2 WHERE note_id = $1", [
                  id,
                  newer
                ])

                send(parent, :locked)

                receive do
                  :commit -> :ok
                  :rollback -> Repo.rollback(:test_failed)
                end
              end)
            end)
          end)

        track(:writer, writer)
        assert_receive :locked, 5_000

        heal =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn -> String.to_existing_atom(@mod).heal(Repo) end)
          end)

        track(:heal, heal)
        await_blocked_heal()
        send(writer.pid, :commit)

        assert {:ok, :ok} = Task.await(writer)
        assert :ok = Task.await(heal)
        assert content_ct(id) == [[newer]]
      after
        stop_tasks()
        assert cleanup(started) == []
      end
    end)

    # Nothing committed outlives the test (CI's ContentOutboxTest once saw
    # this test's NoteCommitted job).
    user_id = Ecto.UUID.dump!(tracked(:user).id)
    assert Sandbox.unboxed_run(Repo, fn -> leftovers(user_id) end) == [[0, 0, jobs_before]]
  end
end
