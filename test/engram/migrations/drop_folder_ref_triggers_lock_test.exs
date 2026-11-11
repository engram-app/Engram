defmodule Engram.Migrations.DropFolderRefTriggersLockTest do
  @moduledoc """
  20261111000000 runs at boot. A DROP TRIGGER that hits its 5 s
  `lock_timeout` (55P03) on a busy `notes` table must be retried, not fail
  every task.
  """
  use Engram.DataCase, async: false

  alias Engram.LockTimeoutRepo

  setup_all do
    Code.require_file(
      "priv/repo/migrations/20261111000000_drop_notes_set_folder_ref_triggers_contract.exs"
    )

    :ok
  end

  defp migration,
    do:
      String.to_existing_atom(
        "Elixir.Engram.Repo.Migrations.DropNotesSetFolderRefTriggersContract"
      )

  defp trigger?(name) do
    %{rows: [[n]]} =
      Engram.Repo.query!(
        "SELECT count(*) FROM pg_trigger WHERE tgrelid = 'notes'::regclass AND tgname = $1",
        [name]
      )

    n == 1
  end

  test "a DROP TRIGGER that hits its lock timeout is retried, then the drop lands" do
    migration().run_down(Engram.Repo)
    assert trigger?("notes_set_folder_ref")

    LockTimeoutRepo.refuse(1)
    assert :ok = migration().run_up(LockTimeoutRepo)

    assert LockTimeoutRepo.left() == 0
    refute trigger?("notes_set_folder_ref")
    refute trigger?("notes_set_folder_ref_on_restore")
    assert trigger?("notes_folder_ref_live_only")
  end

  test "it gives up after its retries" do
    LockTimeoutRepo.refuse(3)
    assert_raise Postgrex.Error, fn -> migration().run_up(LockTimeoutRepo) end
  end
end
