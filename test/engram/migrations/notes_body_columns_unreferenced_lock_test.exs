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

  test "a statement that hits its lock timeout is retried, then succeeds" do
    LockTimeoutRepo.refuse(2)
    assert :ok = migration().with_lock_timeout(LockTimeoutRepo, ["SELECT 1"])
    assert LockTimeoutRepo.left() == 0
  end

  test "it gives up after its retries" do
    LockTimeoutRepo.refuse(3)

    assert_raise Postgrex.Error, fn ->
      migration().with_lock_timeout(LockTimeoutRepo, ["SELECT 1"])
    end
  end
end
