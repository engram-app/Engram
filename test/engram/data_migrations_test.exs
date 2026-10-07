defmodule Engram.DataMigrationsTest do
  # async: false: done?/2 caches in :persistent_term, which is node-global.
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.DataMigrations
  alias Engram.Notes.Note

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

    test "is false on an empty set" do
      insert(:user)
      refute DataMigrations.any_row?(from(n in Note, select: 1))
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
