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
      assert DataMigrations.any_row?(fn _repo -> from(n in Note, select: 1) end)
    end

    test "is false on an empty set" do
      insert(:user)
      refute DataMigrations.any_row?(fn _repo -> from(n in Note, select: 1) end)
    end
  end

  describe "jobs_in_flight?/1" do
    test "sees an available job of that worker only" do
      refute DataMigrations.jobs_in_flight?(Engram.Workers.BackfillNoteLinks)

      %{
        "user_id" => Ecto.UUID.generate(),
        "vault_id" => Ecto.UUID.generate(),
        "cursor" => "",
        "scope" => "note_hmacs"
      }
      |> Engram.Workers.BackfillNoteLinks.new()
      |> Oban.insert!()

      assert DataMigrations.jobs_in_flight?(Engram.Workers.BackfillNoteLinks)
      refute DataMigrations.jobs_in_flight?(Engram.Workers.BackfillContentHashHmac)
    end
  end
end
