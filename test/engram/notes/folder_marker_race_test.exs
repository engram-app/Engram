defmodule Engram.Notes.FolderMarkerRaceTest do
  # `Notes.create_folder_marker/3` (behind `FoldersController#create`) raced under
  # concurrent creates of the SAME folder: `find_folder_marker` returns
  # `:not_found` for both callers, both attempt `insert_folder_marker`, and the
  # loser hits the `notes_user_vault_folder_marker` unique index.
  #
  # The violation aborted the ENTIRE `Repo.with_tenant` transaction — its trailing
  # `set_config('role','none')` role-reset query then failed with
  # `25P02 in_failed_sql_transaction`, so the create returned an error and the
  # controller 500'd instead of idempotently returning the winner's marker.
  # (Observed in CI e2e-clerk: two `FoldersController#create` 500s, each preceded
  # by a `duplicate key ... notes_user_vault_folder_marker` Postgres error.)
  #
  # The fix wraps the insert in a SAVEPOINT (nested `Repo.transaction`) so a
  # unique violation rolls back ONLY the insert, keeping the tenant transaction
  # alive to re-fetch the winner's marker — the recovery path that already
  # existed but was unreachable because the txn was poisoned before it ran.
  #
  # As documented in `ensure_user_dek_race_test`, ExUnit's shared sandbox
  # serializes these tasks through a single connection, so this does NOT trigger
  # the SQL-level race in isolation. It verifies the invariant the fix
  # guarantees: parallel creates of the same folder all succeed and converge on a
  # single marker row, and never surface an error.
  use Engram.DataCase, async: false

  alias Engram.Notes
  alias Engram.Notes.Note

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  test "parallel create_folder_marker for the same folder all succeed, one marker",
       %{user: user, vault: vault} do
    parent = self()

    results =
      1..4
      |> Task.async_stream(
        fn _ ->
          # Allow the spawned task to use the parent's sandbox connection.
          Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, parent, self())
          Notes.create_folder_marker(user, vault, "Shared")
        end,
        max_concurrency: 4,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, %Note{}}, &1)),
           "every concurrent create must succeed (no 500/abort), got: #{inspect(results)}"

    ids = results |> Enum.map(fn {:ok, m} -> m.id end) |> Enum.uniq()

    assert length(ids) == 1,
           "expected the concurrent creates to converge on one marker, got: #{inspect(ids)}"
  end

  test "create_folder_marker is idempotent across sequential calls",
       %{user: user, vault: vault} do
    {:ok, m1} = Notes.create_folder_marker(user, vault, "Foo")
    {:ok, m2} = Notes.create_folder_marker(user, vault, "Foo")
    assert m1.id == m2.id
  end
end
