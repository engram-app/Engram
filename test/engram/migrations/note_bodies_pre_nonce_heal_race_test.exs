defmodule Engram.Migrations.NoteBodiesPreNonceHealRaceTest do
  @moduledoc """
  A writer sets a note's body between the heal's read and its UPDATE. The
  sandbox runs every statement on one connection, one after another, so
  this runs outside it: a writer connection holds the body row locked with
  a newer body, the heal (its own connection) reads the old snapshot and
  blocks on that row in its UPDATE, then the writer commits. Under READ
  COMMITTED the UPDATE re-reads the committed row; only the CASE guard in
  `SET` (fill a NULL body, else keep it) stops it writing the stale `notes`
  copy over the newer body. The user and its rows are deleted in an `after`.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Notes, Repo}

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

  test "a body written between the heal's read and its UPDATE is kept" do
    Sandbox.unboxed_run(Repo, fn ->
      {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))

      try do
        {:ok, vault, _} = Engram.Vaults.register_vault(user, "Race", Ecto.UUID.generate())

        {:ok, note} =
          Notes.upsert_note(user, vault, %{"path" => "race.md", "content" => "old"}, actor: "api")

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
                receive do: (:commit -> :ok)
              end)
            end)
          end)

        assert_receive :locked, 5_000

        heal =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn -> String.to_existing_atom(@mod).heal(Repo) end)
          end)

        await_blocked_heal()
        send(writer.pid, :commit)

        assert {:ok, :ok} = Task.await(writer)
        assert :ok = Task.await(heal)
        assert content_ct(id) == [[newer]]
      after
        Repo.query!("DELETE FROM notes WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])
        Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
      end
    end)
  end
end
