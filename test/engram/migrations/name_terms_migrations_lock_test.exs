defmodule Engram.Migrations.NameTermsMigrationsLockTest do
  @moduledoc """
  20261111020000 (create `name_terms`) and 20261111020100 (`name_terms_stamp`)
  run at boot. A statement that hits its 5 s `lock_timeout` (55P03) on a busy
  `vaults` or `notes` table must be retried, not crash every task, and a
  rerun after a partial run must land.
  """
  use Engram.DataCase, async: false

  alias Engram.LockTimeoutRepo

  @files [
    "priv/repo/migrations/20261111020000_create_name_terms_expand.exs",
    "priv/repo/migrations/20261111020100_add_name_terms_stamp_expand.exs"
  ]

  setup_all do
    Enum.each(@files, &Code.require_file/1)
    :ok
  end

  defp create_table,
    do: String.to_existing_atom("Elixir.Engram.Repo.Migrations.CreateNameTermsExpand")

  defp add_stamp,
    do: String.to_existing_atom("Elixir.Engram.Repo.Migrations.AddNameTermsStampExpand")

  defp table?,
    do: Engram.Repo.query!("SELECT 1 FROM pg_class WHERE relname = 'name_terms'").num_rows == 1

  defp policies do
    Engram.Repo.query!(
      "SELECT policyname FROM pg_policies WHERE tablename = 'name_terms' ORDER BY 1"
    ).rows
  end

  defp column?(table) do
    Engram.Repo.query!(
      "SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = 'name_terms_stamp'",
      [table]
    ).num_rows == 1
  end

  describe "create name_terms" do
    test "a statement that hits its lock timeout is retried, then the table lands" do
      create_table().run_down(Engram.Repo)
      refute table?()

      LockTimeoutRepo.refuse(2)
      assert :ok = create_table().run_up(LockTimeoutRepo)

      assert LockTimeoutRepo.left() == 0
      assert table?()
      assert policies() == [["maintenance_all"], ["tenant_isolation_name_terms"]]
    end

    test "a rerun over a landed table is a no-op" do
      assert :ok = create_table().run_up(Engram.Repo)
      assert :ok = create_table().run_up(Engram.Repo)
      assert policies() == [["maintenance_all"], ["tenant_isolation_name_terms"]]
    end

    test "it gives up after its retries" do
      LockTimeoutRepo.refuse(3)
      assert_raise Postgrex.Error, fn -> create_table().run_up(LockTimeoutRepo) end
    end
  end

  describe "add name_terms_stamp" do
    test "a statement that hits its lock timeout is retried, then both columns land" do
      add_stamp().run_down(Engram.Repo)
      refute column?("notes")

      LockTimeoutRepo.refuse(2)
      assert :ok = add_stamp().run_up(LockTimeoutRepo)

      assert LockTimeoutRepo.left() == 0
      assert column?("notes") and column?("folders")
      # Rerun-safe.
      assert :ok = add_stamp().run_up(Engram.Repo)
    end

    test "it gives up after its retries" do
      LockTimeoutRepo.refuse(3)
      assert_raise Postgrex.Error, fn -> add_stamp().run_up(LockTimeoutRepo) end
    end
  end
end
