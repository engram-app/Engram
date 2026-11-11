defmodule Engram.Migrations.NotesBodyColumnsUnreferencedLockTest do
  @moduledoc """
  20261107140100 runs at boot. A statement that hits its 5 s `lock_timeout`
  (55P03) on a busy `notes` table must be retried, not crash every task.
  """
  use Engram.DataCase, async: false

  # Refuses the first `:left` statements with a lock timeout, then passes
  # through. Same fake as `NoteFolderHashPrepTimeoutTest`'s.
  defmodule LockedRepo do
    @moduledoc false
    def checkout(fun, opts), do: Engram.Repo.checkout(fun, opts)
    defdelegate query!(sql), to: Engram.Repo

    def query!(sql, params, opts) do
      left = :persistent_term.get({__MODULE__, :left})

      if left > 0 do
        :persistent_term.put({__MODULE__, :left}, left - 1)

        raise %Postgrex.Error{
          postgres: %{
            code: :lock_not_available,
            pg_code: "55P03",
            severity: "ERROR",
            message: "lock timeout"
          }
        }
      end

      Engram.Repo.query!(sql, params, opts)
    end
  end

  setup_all do
    Code.require_file(
      "priv/repo/migrations/20261107140100_notes_body_columns_unreferenced_expand.exs"
    )

    on_exit(fn -> :persistent_term.erase({LockedRepo, :left}) end)
    :ok
  end

  defp migration,
    do: String.to_existing_atom("Elixir.Engram.Repo.Migrations.NotesBodyColumnsUnreferencedExpand")

  test "a statement that hits its lock timeout is retried, then succeeds" do
    :persistent_term.put({LockedRepo, :left}, 2)
    assert :ok = migration().with_lock_timeout(LockedRepo, ["SELECT 1"])
    assert :persistent_term.get({LockedRepo, :left}) == 0
  end

  test "it gives up after its retries" do
    :persistent_term.put({LockedRepo, :left}, 3)

    assert_raise Postgrex.Error, fn ->
      migration().with_lock_timeout(LockedRepo, ["SELECT 1"])
    end
  end
end
