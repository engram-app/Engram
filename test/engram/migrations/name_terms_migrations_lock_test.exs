defmodule Engram.Migrations.NameTermsMigrationsLockTest do
  @moduledoc """
  20261111020000 (create `name_terms`) and 20261111020100 (`name_terms_stamp`)
  run at boot. A statement that hits its 5 s `lock_timeout` (55P03) on a busy
  `vaults` or `notes` table must be retried, not crash every task, and a
  rerun after a partial run must land.
  """
  use Engram.DataCase, async: false

  import ExUnit.CaptureLog

  alias Engram.LockTimeoutRepo

  @files [
    "priv/repo/migrations/20261111020000_create_name_terms_expand.exs",
    "priv/repo/migrations/20261111020100_add_name_terms_stamp_expand.exs",
    "priv/repo/migrations/migration_log.exs"
  ]

  # The CONCURRENTLY builds cannot run in a sandbox transaction: their line
  # comes from `MigrationLog.indexes/4`, after a `flush()`.
  @cic [
    {"priv/repo/migrations/20261111020200_index_name_terms_stale_expand.exs",
     ~w(notes_name_terms_stale folders_name_terms_stale)},
    {"priv/repo/migrations/20261111020300_index_notes_folder_ref_live_id_expand.exs",
     ~w(folders_live_parent_id notes_folder_ref_live_id)}
  ]

  setup_all do
    Enum.each(@files, &Engram.MigrationFile.load!(Path.basename(&1)))
    :ok
  end

  defp create_table,
    do: String.to_existing_atom("Elixir.Engram.Repo.Migrations.CreateNameTermsExpand")

  defp add_stamp,
    do: String.to_existing_atom("Elixir.Engram.Repo.Migrations.AddNameTermsStampExpand")

  defp migration_log,
    do: String.to_existing_atom("Elixir.Engram.Repo.Migrations.MigrationLog")

  # The one summary line a migration logs at :info (`category: :boot`).
  defp summary(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      log = capture_log([level: :info], fun)
      Regex.scan(~r/migration \w+: [^\n]*\(\d+ ms\)/, log) |> List.flatten()
    after
      Logger.configure(level: previous)
    end
  end

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

  describe "one summary line per migration, counts only" do
    test "create name_terms: whether it created the table, and its policies" do
      create_table().run_down(Engram.Repo)
      assert [line] = summary(fn -> create_table().run_up(Engram.Repo) end)
      assert line =~ "migration create_name_terms: table_created 1, policies 2 ("

      assert [line] = summary(fn -> create_table().run_up(Engram.Repo) end)
      assert line =~ "table_created 0, policies 2"
    end

    test "add name_terms_stamp: columns present" do
      add_stamp().run_down(Engram.Repo)
      assert [line] = summary(fn -> add_stamp().run_up(Engram.Repo) end)
      assert line =~ "migration add_name_terms_stamp: columns_present 2/2 ("
    end

    test "the index builds report their valid indexes and estimated entries" do
      for {file, indexes} <- @cic do
        source = File.read!(file)
        [_, after_flush] = String.split(source, "flush()", parts: 2)
        assert after_flush =~ ~r/MigrationLog\.indexes\(\s*repo\(\),/
        for index <- indexes, do: assert(after_flush =~ index)

        assert [line] =
                 summary(fn ->
                   migration_log().indexes(Engram.Repo, "x", indexes, migration_log().now())
                 end)

        assert line =~ ~r/migration x: indexes_valid 2\/2, entries_est \d+ \(/
      end
    end
  end
end
