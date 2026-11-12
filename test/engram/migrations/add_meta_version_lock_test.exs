defmodule Engram.Migrations.AddMetaVersionLockTest do
  @moduledoc """
  20261111150000 runs at boot and takes ACCESS EXCLUSIVE on `notes`. A
  statement that hits its 5 s `lock_timeout` (55P03) must be retried, not
  queue every notes read and write behind it or crash every task.
  """
  use Engram.DataCase, async: false

  import ExUnit.CaptureLog

  alias Engram.LockTimeoutRepo

  setup_all do
    Engram.MigrationFile.load!("20261111150000_add_meta_version_to_notes_expand.exs")
    :ok
  end

  defp migration,
    do: String.to_existing_atom("Elixir.Engram.Repo.Migrations.AddMetaVersionToNotesExpand")

  defp column? do
    Engram.Repo.query!("""
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'notes' AND column_name = 'meta_version'
    """).rows != []
  end

  test "a statement that hits its lock timeout is retried, then the column lands" do
    migration().run_down(Engram.Repo)
    refute column?()

    LockTimeoutRepo.refuse(2)
    assert :ok = migration().run_up(LockTimeoutRepo)

    assert LockTimeoutRepo.left() == 0
    assert column?()
    # Rerun-safe.
    assert :ok = migration().run_up(Engram.Repo)
  end

  test "it gives up after its retries" do
    LockTimeoutRepo.refuse(3)
    assert_raise Postgrex.Error, fn -> migration().run_up(LockTimeoutRepo) end
  end

  test "one summary line, counts only: the column present" do
    migration().run_down(Engram.Repo)
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    log = capture_log([level: :info], fn -> migration().run_up(Engram.Repo) end)
    assert [_] = Regex.scan(~r/migration add_meta_version: columns_present 1\/1 \(\d+ ms\)/, log)
  end
end
