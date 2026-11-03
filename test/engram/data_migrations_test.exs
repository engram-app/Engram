defmodule Engram.DataMigrationsTest do
  # async: false: done?/2 caches in :persistent_term, which is node-global.
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.DataMigrations
  alias Engram.Notes.Note
  alias Engram.QueryRecorder

  setup do
    DataMigrations.reset_cache()
    :ok
  end

  describe "note_open/2" do
    alias Engram.DataMigrations.Entry

    defp entry(name), do: Repo.get!(Entry, name)

    test "opens a row and stamps opened_at once" do
      first = DataMigrations.note_open("m", 1)
      assert first.completed_at == nil
      assert %DateTime{} = first.opened_at

      Repo.update_all(from(e in Entry), set: [opened_at: ~U[2026-01-01 00:00:00.000000Z]])
      DataMigrations.note_open("m", 1)
      assert entry("m").opened_at == ~U[2026-01-01 00:00:00.000000Z]
    end

    test "a version bump resets opened_at and alerted_at" do
      DataMigrations.note_open("m", 1)
      old = ~U[2026-01-01 00:00:00.000000Z]
      Repo.update_all(from(e in Entry), set: [opened_at: old, alerted_at: old])

      DataMigrations.note_open("m", 2)
      row = entry("m")
      assert row.version == 2
      assert DateTime.compare(row.opened_at, old) == :gt
      assert row.alerted_at == nil
    end

    # Mixed-version fleet during a rolling deploy: an old node's pass must not
    # lower the version, or the new node's next note_open sees a "bump" and
    # resets the stuck clock every hour.
    test "an older version neither lowers the version nor resets opened_at" do
      DataMigrations.note_open("m", 2)
      old = ~U[2026-01-01 00:00:00.000000Z]
      Repo.update_all(from(e in Entry), set: [opened_at: old])

      DataMigrations.note_open("m", 1)
      assert %{version: 2, opened_at: ^old} = entry("m")

      DataMigrations.note_open("m", 2)
      assert entry("m").opened_at == old
    end

    # An old node finishing ITS version must not close the newer version's work.
    test "mark_done with an older version leaves a newer open row open" do
      DataMigrations.note_open("m", 2)
      :ok = DataMigrations.mark_done("m", 1)

      assert %{version: 2, completed_at: nil} = entry("m")
      refute DataMigrations.done?("m", 2)
    end

    test "mark_done leaves the row closed" do
      DataMigrations.note_open("m", 1)
      :ok = DataMigrations.mark_done("m", 1)
      assert entry("m").completed_at
      assert DataMigrations.done?("m", 1)
    end
  end

  describe "done?/2 and mark_done/2" do
    test "an unknown migration is not done" do
      refute DataMigrations.done?("never_seen", 1)
    end

    test "mark_done makes the same version done" do
      :ok = DataMigrations.mark_done("m", 1)
      assert DataMigrations.done?("m", 1)
    end

    test "a higher code version reopens it" do
      :ok = DataMigrations.mark_done("m", 1)
      refute DataMigrations.done?("m", 2)
    end

    test "a rollback to an older version still reads done" do
      :ok = DataMigrations.mark_done("m", 2)
      assert DataMigrations.done?("m", 1)
    end

    test "mark_done upserts the version forward" do
      :ok = DataMigrations.mark_done("m", 1)
      :ok = DataMigrations.mark_done("m", 2)
      assert DataMigrations.done?("m", 2)
      assert Repo.aggregate(Engram.DataMigrations.Entry, :count) == 1
    end

    test "a cached true survives without a DB read, and reset_cache clears it" do
      :ok = DataMigrations.mark_done("m", 1)
      assert DataMigrations.done?("m", 1)
      Repo.delete_all(Engram.DataMigrations.Entry)
      assert DataMigrations.done?("m", 1)
      DataMigrations.reset_cache()
      refute DataMigrations.done?("m", 1)
    end
  end

  describe "any_row?/1" do
    test "finds a row owned by any tenant" do
      user = insert(:user)
      insert(:note, user: user)
      assert DataMigrations.any_row?(from(n in Note, select: 1))
    end

    # #2276: asked inside id windows, never one EXISTS over the whole table.
    test "finds the last row by windows, every statement one window" do
      user = insert(:user)
      notes = for _ <- 1..5, do: insert(:note, user: user)
      last = Enum.max_by(notes, & &1.id)

      {found, queries} =
        QueryRecorder.record(fn ->
          DataMigrations.any_row?(from(n in Note, where: n.id == ^last.id, select: 1))
        end)

      assert found
      assert QueryRecorder.unwindowed(queries, "notes", 1_000) == []
    end

    test "is false on an empty set" do
      insert(:user)
      refute DataMigrations.any_row?(from(n in Note, select: 1))
    end
  end

  describe "reopen/2 is cluster-wide" do
    # Without a daily re-verify, a hand reopen (after a restore with triggers
    # disabled) is the only way back to work. `done?/2` caches `true` per
    # node for the node's lifetime, so a reopen that cleared only its own
    # node left the runner skipping on every other node until a restart.
    test "a reopen broadcasts it on the cache-sync topic" do
      :ok = Engram.Cluster.CacheSync.subscribe()
      :ok = DataMigrations.mark_done("test_reopen", 1)
      assert DataMigrations.done?("test_reopen", 1)

      :ok = DataMigrations.reopen("test_reopen", 1)

      assert_receive {:cache_sync, {:data_migration_reopen, "test_reopen", 1}}
      refute DataMigrations.cached_done?("test_reopen", 1)
      refute DataMigrations.done?("test_reopen", 1)
    end

    test "a peer's reopen drops this node's cached done" do
      :ok = DataMigrations.mark_done("test_reopen", 1)
      assert DataMigrations.done?("test_reopen", 1)
      assert DataMigrations.cached_done?("test_reopen", 1)

      # What a peer's reopen/2 sends; this node never ran the reopen.
      :ok = Engram.Cluster.CacheSync.broadcast({:data_migration_reopen, "test_reopen", 1})
      _ = :sys.get_state(Engram.Cache.Server)

      refute DataMigrations.cached_done?("test_reopen", 1)
    end
  end

  describe "jobs_in_flight?/1" do
    test "sees an available job of that worker only" do
      refute DataMigrations.jobs_in_flight?(Engram.Workers.BackfillCrdtHead)

      %{
        "user_id" => Ecto.UUID.generate(),
        "vault_id" => Ecto.UUID.generate(),
        "cursor" => ""
      }
      |> Engram.Workers.BackfillCrdtHead.new()
      |> Oban.insert!()

      assert DataMigrations.jobs_in_flight?(Engram.Workers.BackfillCrdtHead)
      refute DataMigrations.jobs_in_flight?(Engram.Workers.BackfillCrdtState)
    end
  end
end
