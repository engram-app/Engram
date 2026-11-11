defmodule Engram.Migrations.NotesBodyColumnsUnreferencedLockTest do
  @moduledoc """
  20261111000100 runs at boot. A statement that hits its 5 s `lock_timeout`
  (55P03) on a busy `notes` table must be retried, not crash every task.
  """
  use Engram.DataCase, async: false

  alias Engram.LockTimeoutRepo

  setup_all do
    Code.require_file(
      "priv/repo/migrations/20261111000100_notes_body_columns_unreferenced_expand.exs"
    )

    :ok
  end

  defp migration,
    do:
      String.to_existing_atom("Elixir.Engram.Repo.Migrations.NotesBodyColumnsUnreferencedExpand")

  defp constraint?(name) do
    Engram.Repo.query!("SELECT 1 FROM pg_constraint WHERE conname = $1", [name]).num_rows == 1
  end

  test "a statement that hits its lock timeout is retried, then the migration lands" do
    migration().run_down(Engram.Repo)
    assert constraint?("notes_kind_shape_v3_check")

    LockTimeoutRepo.refuse(2)
    assert :ok = migration().run_up(LockTimeoutRepo)

    assert LockTimeoutRepo.left() == 0
    assert constraint?("notes_kind_shape_v4_check")
    refute constraint?("notes_kind_shape_v3_check")
  end

  test "it gives up after its retries" do
    LockTimeoutRepo.refuse(3)
    assert_raise Postgrex.Error, fn -> migration().run_up(LockTimeoutRepo) end
  end
end
