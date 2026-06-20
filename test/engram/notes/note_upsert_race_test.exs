defmodule Engram.Notes.NoteUpsertRaceTest do
  # `NotesController#upsert` / `Notes.upsert_note` had the same check-then-insert
  # race as folder markers (see folder_marker_race_test): concurrent upserts of
  # the same NEW path both see `nil` on the lookup, both insert, and the loser
  # hits the `notes_user_vault_path_v2` unique index.
  #
  # The violation aborted the whole `Repo.with_tenant` transaction — its trailing
  # role-reset query then failed with `25P02` → the controller returned **500**.
  # Observed in CI e2e-clerk: two `NotesController#upsert status=500` each
  # preceded by a `duplicate key ... notes_user_vault_path_v2` Postgres error.
  #
  # That 500 was the root cause of the `test_24` offline-queue replay flake: the
  # plugin's `flushQueue` treats a 409 conflict as a returned value (dequeue +
  # continue) but a 500 as a thrown error — it breaks the drain pass and flips
  # offline, so the queue never empties. With concurrent flushes double-pushing
  # the same queued notes, the loser's push 500'd and stalled the whole drain.
  #
  # The fix savepoints the insert so the unique violation rolls back only the
  # insert, keeping the tenant transaction alive to report a version conflict
  # (→ 409) the client reconciles — instead of a 500.
  #
  # As with `ensure_user_dek_race_test`, ExUnit's shared sandbox serializes the
  # tasks through one connection, so this does NOT trigger the SQL race in
  # isolation. It verifies the invariant the fix guarantees: parallel upserts of
  # the same new path all resolve CLEANLY (a successful upsert or a version
  # conflict — never a `{:error, changeset}`/500/raise) and converge on a single
  # note row.
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  test "parallel upsert of the same new path all resolve cleanly, one note row",
       %{user: user, vault: vault} do
    parent = self()
    attrs = %{"path" => "Race.md", "content" => "# Race", "mtime" => 1_700_000_000.0}

    results =
      1..4
      |> Task.async_stream(
        fn _ ->
          # Allow the spawned task to use the parent's sandbox connection.
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          Notes.upsert_note(user, vault, attrs)
        end,
        max_concurrency: 4,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    # The fix's core guarantee: a concurrent-create race resolves as a clean
    # upsert or a version conflict — NEVER a raw changeset error (which the
    # controller renders as a 500).
    assert Enum.all?(results, fn
             {:ok, %Note{}} -> true
             {:error, :version_conflict, _} -> true
             _ -> false
           end),
           "every concurrent upsert must resolve cleanly (ok | version_conflict), got: #{inspect(results)}"

    # Exactly one live note row exists at that path.
    {:ok, count} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and
                n.kind == "note" and is_nil(n.deleted_at)
          ),
          :count
        )
      end)

    assert count == 1, "expected one note row, got #{count}"
  end

  test "sequential upsert of the same path is idempotent (no error)",
       %{user: user, vault: vault} do
    attrs = %{"path" => "Seq.md", "content" => "# Seq", "mtime" => 1_700_000_000.0}
    assert {:ok, %Note{} = n1} = Notes.upsert_note(user, vault, attrs)
    assert {:ok, %Note{} = n2} = Notes.upsert_note(user, vault, attrs)
    assert n1.id == n2.id
  end
end
