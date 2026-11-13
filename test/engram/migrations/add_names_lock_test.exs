defmodule Engram.Migrations.AddNamesLockTest do
  @moduledoc """
  20261111030000 runs at boot and takes ACCESS EXCLUSIVE on `notes`,
  `attachments` and `folders`. A statement that hits its 5 s `lock_timeout`
  (55P03) must be retried, not crash every task, and each table's ALTER is
  its own statement, so the three are never locked together.
  """
  use Engram.DataCase, async: false

  import ExUnit.CaptureLog

  alias Engram.LockTimeoutRepo

  setup_all do
    Engram.MigrationFile.load!("20261111030000_add_names_expand.exs")
    :ok
  end

  defp migration,
    do: String.to_existing_atom("Elixir.Engram.Repo.Migrations.AddNamesExpand")

  # Runs the migration's down out of order, on the current schema: a later
  # migration's object that depends on a column it drops goes first, as a
  # rollback in order would drop it first. 20261113100000's
  # `notes_set_name_key` fires on `UPDATE OF ... name_stamp`, so it depends
  # on S2's columns. Inside the test's transaction, rolled back with it.
  defp run_down! do
    Engram.Repo.query!("DROP TRIGGER IF EXISTS notes_set_name_key ON notes")
    migration().run_down(Engram.Repo)
  end

  defp columns do
    Engram.Repo.query!("""
    SELECT table_name || '.' || column_name FROM information_schema.columns
    WHERE table_name IN ('notes', 'attachments', 'folders')
      AND column_name IN ('name_ciphertext', 'name_nonce', 'name_hmac', 'name_ci_hmac',
                          'name_stamp', 'seq', 'notes_cascaded')
    """).rows
    |> List.flatten()
    |> Enum.sort()
  end

  test "a statement that hits its lock timeout is retried, then every column lands" do
    landed = columns()
    run_down!()
    # Folders' own name columns predate S2; only the ones S2 adds are gone.
    refute Enum.any?(
             columns(),
             &(&1 =~
                 ~r/^(notes|attachments)\.name_|^folders\.(name_ci_hmac|name_stamp|notes_cascaded)$/)
           )

    LockTimeoutRepo.refuse(2)
    assert :ok = migration().run_up(LockTimeoutRepo)

    assert LockTimeoutRepo.left() == 0
    assert columns() == landed
    # Rerun-safe.
    assert :ok = migration().run_up(Engram.Repo)
  end

  test "it gives up after its retries" do
    LockTimeoutRepo.refuse(3)
    assert_raise Postgrex.Error, fn -> migration().run_up(LockTimeoutRepo) end
  end

  test "one summary line, counts only: the columns present" do
    run_down!()
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    log = capture_log([level: :info], fn -> migration().run_up(Engram.Repo) end)
    assert [_] = Regex.scan(~r/migration add_names: columns_present 14\/14 \(\d+ ms\)/, log)
  end
end
