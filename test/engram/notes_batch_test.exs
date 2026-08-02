defmodule Engram.NotesBatchTest do
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    other_user = insert(:user)

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    insert(:user_limit_override, user: other_user, key: "vaults_cap", value: %{"v" => -1})

    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, other_user} = Engram.Crypto.ensure_user_dek(other_user)

    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    {:ok, other_vault} = Engram.Vaults.create_vault(other_user, %{name: "Test"})

    %{user: user, other_user: other_user, vault: vault, other_vault: other_vault}
  end

  describe "batch_delete_notes/3" do
    test "soft-deletes all listed notes in one transaction", %{user: user, vault: vault} do
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "a.md"})
      {:ok, n2} = Notes.upsert_note(user, vault, %{path: "b.md"})

      assert {:ok, %{deleted: 2}} = Notes.batch_delete_notes(user, vault, [n1.id, n2.id])
      assert {:error, :not_found} = Notes.get_note_by_id(user, vault, n1.id)
      assert {:error, :not_found} = Notes.get_note_by_id(user, vault, n2.id)
    end

    test "rolls back if any id belongs to another vault", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "a.md"})
      {:ok, foreign_note} = Notes.upsert_note(other_user, other_vault, %{path: "f.md"})

      assert {:error, {:not_found, foreign_id}} =
               Notes.batch_delete_notes(user, vault, [n1.id, foreign_note.id])

      assert foreign_id == foreign_note.id

      # Atomicity: n1 must still be readable (prior successful delete rolled back).
      assert {:ok, _} = Notes.get_note_by_id(user, vault, n1.id)

      # And the foreign note untouched for its owner.
      assert {:ok, _} = Notes.get_note_by_id(other_user, other_vault, foreign_note.id)
    end

    test "empty list → {:ok, %{deleted: 0}}", %{user: user, vault: vault} do
      assert {:ok, %{deleted: 0}} = Notes.batch_delete_notes(user, vault, [])
    end
  end

  describe "batch_move_notes/4" do
    test "moves all listed notes to target folder, single transaction", %{
      user: user,
      vault: vault
    } do
      {:ok, target_marker} = Notes.create_folder_marker(user, vault, "Archive")
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "a.md"})
      {:ok, n2} = Notes.upsert_note(user, vault, %{path: "b.md"})

      assert {:ok, %{moved: 2}} =
               Notes.batch_move_notes(user, vault, [n1.id, n2.id], target_marker.id)

      {:ok, n1_after} = Notes.get_note_by_id(user, vault, n1.id)
      assert n1_after.path == "Archive/a.md"

      {:ok, n2_after} = Notes.get_note_by_id(user, vault, n2.id)
      assert n2_after.path == "Archive/b.md"
    end

    test "rolls back on path collision", %{user: user, vault: vault} do
      {:ok, target_marker} = Notes.create_folder_marker(user, vault, "Archive")
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "a.md"})
      {:ok, _conflict} = Notes.upsert_note(user, vault, %{path: "Archive/a.md"})

      assert {:error, {:conflict, conflict_id}} =
               Notes.batch_move_notes(user, vault, [n1.id], target_marker.id)

      assert conflict_id == n1.id

      # Atomicity: n1 untouched.
      {:ok, untouched} = Notes.get_note_by_id(user, vault, n1.id)
      assert untouched.path == "a.md"
    end

    test "rolls back on cross-vault id", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      {:ok, target_marker} = Notes.create_folder_marker(user, vault, "Archive")
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "a.md"})
      {:ok, foreign_note} = Notes.upsert_note(other_user, other_vault, %{path: "f.md"})

      assert {:error, {:not_found, foreign_id}} =
               Notes.batch_move_notes(user, vault, [n1.id, foreign_note.id], target_marker.id)

      assert foreign_id == foreign_note.id

      # Atomicity: n1's prior successful move rolled back.
      {:ok, untouched} = Notes.get_note_by_id(user, vault, n1.id)
      assert untouched.path == "a.md"

      # Foreign note untouched for its owner.
      {:ok, foreign_after} = Notes.get_note_by_id(other_user, other_vault, foreign_note.id)
      assert foreign_after.path == "f.md"
    end

    test "rolls back when target folder marker is missing", %{user: user, vault: vault} do
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "a.md"})
      missing_id = Ecto.UUID.generate()

      assert {:error, {:not_found, ^missing_id}} =
               Notes.batch_move_notes(user, vault, [n1.id], missing_id)

      {:ok, untouched} = Notes.get_note_by_id(user, vault, n1.id)
      assert untouched.path == "a.md"
    end

    test "empty list returns {:ok, %{moved: 0}}", %{user: user, vault: vault} do
      {:ok, target_marker} = Notes.create_folder_marker(user, vault, "Archive")
      assert {:ok, %{moved: 0}} = Notes.batch_move_notes(user, vault, [], target_marker.id)
    end

    test "moves a note in a folder to the vault root via the \"root\" sentinel", %{
      user: user,
      vault: vault
    } do
      {:ok, _marker} = Notes.create_folder_marker(user, vault, "Archive")
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "Archive/a.md"})

      assert {:ok, %{moved: 1}} = Notes.batch_move_notes(user, vault, [n1.id], "root")

      {:ok, moved} = Notes.get_note_by_id(user, vault, n1.id)
      assert moved.path == "a.md"
      assert moved.folder in ["", nil]
    end

    test "moving a root note to root is a no-op move (still ok)", %{user: user, vault: vault} do
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "a.md"})
      assert {:ok, %{moved: 1}} = Notes.batch_move_notes(user, vault, [n1.id], "root")
      {:ok, moved} = Notes.get_note_by_id(user, vault, n1.id)
      assert moved.path == "a.md"
    end

    test "moves notes into a folder by PATH with no marker (derived target)", %{
      user: user,
      vault: vault
    } do
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "a.md"})
      {:ok, n2} = Notes.upsert_note(user, vault, %{path: "b.md"})

      # No create_folder_marker — "Derived/Sub" exists only as a path. Notes
      # should still move into it (derived folders need no marker).
      assert {:ok, %{moved: 2}} =
               Notes.batch_move_notes(user, vault, [n1.id, n2.id], {:path, "Derived/Sub"})

      {:ok, n1_after} = Notes.get_note_by_id(user, vault, n1.id)
      assert n1_after.path == "Derived/Sub/a.md"
      assert n1_after.folder == "Derived/Sub"
    end

    test "path target \"\" moves a note to the vault root", %{user: user, vault: vault} do
      {:ok, _m} = Notes.create_folder_marker(user, vault, "Archive")
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "Archive/a.md"})

      assert {:ok, %{moved: 1}} = Notes.batch_move_notes(user, vault, [n1.id], {:path, ""})

      {:ok, moved} = Notes.get_note_by_id(user, vault, n1.id)
      assert moved.path == "a.md"
    end

    test "path move rolls back on a cross-vault id", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      {:ok, n1} = Notes.upsert_note(user, vault, %{path: "a.md"})
      {:ok, foreign} = Notes.upsert_note(other_user, other_vault, %{path: "f.md"})

      assert {:error, {:not_found, id}} =
               Notes.batch_move_notes(user, vault, [n1.id, foreign.id], {:path, "Derived"})

      assert id == foreign.id
      # Atomic: n1 stayed put.
      {:ok, n1_after} = Notes.get_note_by_id(user, vault, n1.id)
      assert n1_after.path == "a.md"
    end
  end

  describe "batch_delete_folders/2" do
    test "cascades each folder marker + descendants in one transaction",
         %{user: user, vault: vault} do
      {:ok, m1} = Notes.create_folder_marker(user, vault, "A")
      {:ok, m2} = Notes.create_folder_marker(user, vault, "B")

      {:ok, _} = Notes.upsert_note(user, vault, %{path: "A/a.md"})
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "B/b.md"})

      # 2 markers + 2 child notes = 4 rows total.
      assert {:ok, %{deleted: 4}} =
               Notes.batch_delete_folders(user, vault, [m1.id, m2.id])

      assert {:error, :not_found} = Notes.get_note(user, vault, "A/a.md")
      assert {:error, :not_found} = Notes.get_note(user, vault, "B/b.md")
    end

    test "rolls back if any id is missing/cross-vault", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      {:ok, m1} = Notes.create_folder_marker(user, vault, "Keep")
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "Keep/a.md"})

      {:ok, foreign_marker} =
        Notes.create_folder_marker(other_user, other_vault, "Foreign")

      assert {:error, {:not_found, fid}} =
               Notes.batch_delete_folders(user, vault, [m1.id, foreign_marker.id])

      assert fid == foreign_marker.id

      # Atomicity: m1's prior cascade rolled back.
      assert {:ok, _} = Notes.get_note(user, vault, "Keep/a.md")

      # Foreign marker untouched for its owner.
      {:ok, folders} = Notes.list_folders_with_counts(other_user, other_vault)
      assert "Foreign" in Enum.map(folders, & &1.folder)
    end

    test "empty list → {:ok, %{deleted: 0}}", %{user: user, vault: vault} do
      assert {:ok, %{deleted: 0}} = Notes.batch_delete_folders(user, vault, [])
    end

    test "batch_delete_folders reports the resolved folder paths it touched", %{
      user: user,
      vault: vault
    } do
      {:ok, marker} = Notes.create_folder_marker(user, vault, "Docs")

      assert {:ok, %{deleted: _, folders: folders}} =
               Notes.batch_delete_folders(user, vault, [marker.id])

      assert folders == ["Docs"]
    end

    test "scans the vault once for the whole batch, not once per marker", %{
      user: user,
      vault: vault
    } do
      # Each folder cascade used to re-fetch and re-decrypt EVERY live row
      # in the vault per marker id — a 10-folder batch in a 10k-note vault
      # meant 10 full-vault decrypt passes inside one transaction.
      {:ok, m1} = Notes.create_folder_marker(user, vault, "F1")
      {:ok, m2} = Notes.create_folder_marker(user, vault, "F2")
      {:ok, m3} = Notes.create_folder_marker(user, vault, "F3")
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "F1/a.md"})
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "F2/b.md"})
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "F3/c.md"})

      {result, queries} =
        with_notes_query_count(fn ->
          Notes.batch_delete_folders(user, vault, [m1.id, m2.id, m3.id])
        end)

      assert {:ok, %{deleted: 6}} = result

      # 3 marker lookups + 1 vault scan + 1 update_all (+1 headroom).
      # The per-marker shape costs >= 9 (3 lookups + 3 scans + 3 updates).
      assert queries <= 6,
             "expected a single shared vault scan, saw #{queries} notes-table queries"
    end
  end

  describe "batch_move_folders/3" do
    test "moves each folder into target folder, single transaction",
         %{user: user, vault: vault} do
      {:ok, target_marker} = Notes.create_folder_marker(user, vault, "Parent")
      {:ok, m1} = Notes.create_folder_marker(user, vault, "A")
      {:ok, m2} = Notes.create_folder_marker(user, vault, "B")

      {:ok, _} = Notes.upsert_note(user, vault, %{path: "A/a.md"})

      assert {:ok, %{moved: 2}} =
               Notes.batch_move_folders(user, vault, [m1.id, m2.id], target_marker.id)

      assert {:ok, %{path: "Parent/A/a.md"}} =
               Notes.get_note(user, vault, "Parent/A/a.md")

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      names = Enum.map(folders, & &1.folder)
      assert "Parent/A" in names
      assert "Parent/B" in names
      refute "A" in names
      refute "B" in names
    end

    test "moves a folder into a derived target by PATH (no marker)", %{
      user: user,
      vault: vault
    } do
      {:ok, m1} = Notes.create_folder_marker(user, vault, "A")
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "A/a.md"})

      # "Derived" has no marker — the folder still moves into it by path.
      assert {:ok, %{moved: 1}} =
               Notes.batch_move_folders(user, vault, [m1.id], {:path, "Derived"})

      assert {:ok, %{path: "Derived/A/a.md"}} = Notes.get_note(user, vault, "Derived/A/a.md")
    end

    test "rolls back on conflict (target already has a same-named child)",
         %{user: user, vault: vault} do
      {:ok, target_marker} = Notes.create_folder_marker(user, vault, "Parent")
      {:ok, _conflict} = Notes.create_folder_marker(user, vault, "Parent/A")

      {:ok, m1} = Notes.create_folder_marker(user, vault, "A")
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "A/a.md"})

      assert {:error, {:conflict, mid}} =
               Notes.batch_move_folders(user, vault, [m1.id], target_marker.id)

      assert mid == m1.id

      # Atomicity: A/a.md still readable at original path.
      assert {:ok, %{path: "A/a.md"}} = Notes.get_note(user, vault, "A/a.md")
    end

    test "rolls back on cross-vault id", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      {:ok, target_marker} = Notes.create_folder_marker(user, vault, "Parent")
      {:ok, m1} = Notes.create_folder_marker(user, vault, "A")
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "A/a.md"})

      {:ok, foreign_marker} =
        Notes.create_folder_marker(other_user, other_vault, "Foreign")

      assert {:error, {:not_found, fid}} =
               Notes.batch_move_folders(user, vault, [m1.id, foreign_marker.id], target_marker.id)

      assert fid == foreign_marker.id

      # Atomicity: m1's prior move rolled back.
      assert {:ok, %{path: "A/a.md"}} = Notes.get_note(user, vault, "A/a.md")
    end

    test "rolls back when target folder marker is missing", %{user: user, vault: vault} do
      {:ok, m1} = Notes.create_folder_marker(user, vault, "A")
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "A/a.md"})
      missing_id = Ecto.UUID.generate()

      assert {:error, {:not_found, ^missing_id}} =
               Notes.batch_move_folders(user, vault, [m1.id], missing_id)

      assert {:ok, %{path: "A/a.md"}} = Notes.get_note(user, vault, "A/a.md")
    end

    test "empty list → {:ok, %{moved: 0}}", %{user: user, vault: vault} do
      {:ok, target_marker} = Notes.create_folder_marker(user, vault, "Parent")
      assert {:ok, %{moved: 0}} = Notes.batch_move_folders(user, vault, [], target_marker.id)
    end

    test "moves a nested folder to the vault root via the \"root\" sentinel", %{
      user: user,
      vault: vault
    } do
      {:ok, _parent} = Notes.create_folder_marker(user, vault, "A")
      {:ok, child} = Notes.create_folder_marker(user, vault, "A/B")
      {:ok, note} = Notes.upsert_note(user, vault, %{path: "A/B/x.md"})

      assert {:ok, %{moved: 1}} = Notes.batch_move_folders(user, vault, [child.id], "root")

      {:ok, moved} = Notes.get_note_by_id(user, vault, note.id)
      assert moved.path == "B/x.md"
    end

    test "batch_move_folders reports {old, new} folder pairs", %{user: user, vault: vault} do
      {:ok, src} = Notes.create_folder_marker(user, vault, "Docs")
      {:ok, _dst} = Notes.create_folder_marker(user, vault, "Archive")

      assert {:ok, %{moved: 1, pairs: pairs}} =
               Notes.batch_move_folders(user, vault, [src.id], {:path, "Archive"})

      assert pairs == [{"Docs", "Archive/Docs"}]
    end

    test "moving a parent and its child in one batch tracks the child's post-move path", %{
      user: user,
      vault: vault
    } do
      # After "A" moves under Parent, its subtree (incl. the "A/B" marker and
      # its note) lives at "Parent/A/..." — the second move must operate on
      # THAT state, not the pre-batch snapshot, ending with "A/B" extracted to
      # "Parent/B".
      {:ok, _target} = Notes.create_folder_marker(user, vault, "Parent")
      {:ok, a} = Notes.create_folder_marker(user, vault, "A")
      {:ok, ab} = Notes.create_folder_marker(user, vault, "A/B")
      {:ok, na} = Notes.upsert_note(user, vault, %{path: "A/a.md"})
      {:ok, nb} = Notes.upsert_note(user, vault, %{path: "A/B/b.md"})

      assert {:ok, %{moved: 2, pairs: pairs}} =
               Notes.batch_move_folders(user, vault, [a.id, ab.id], {:path, "Parent"})

      assert pairs == [{"A", "Parent/A"}, {"Parent/A/B", "Parent/B"}]

      {:ok, moved_a} = Notes.get_note_by_id(user, vault, na.id)
      assert moved_a.path == "Parent/A/a.md"

      {:ok, moved_b} = Notes.get_note_by_id(user, vault, nb.id)
      assert moved_b.path == "Parent/B/b.md"
    end

    test "scans the vault once for the whole batch, not once per marker", %{
      user: user,
      vault: vault
    } do
      # Same N+1 class as batch_delete_folders above: each marker's
      # rename_folder cascade used to re-fetch + re-decrypt EVERY live row in
      # the vault (fetch_decrypted_live_rows per marker id).
      {:ok, target} = Notes.create_folder_marker(user, vault, "Parent")
      {:ok, m1} = Notes.create_folder_marker(user, vault, "F1")
      {:ok, m2} = Notes.create_folder_marker(user, vault, "F2")
      {:ok, m3} = Notes.create_folder_marker(user, vault, "F3")
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "F1/a.md"})
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "F2/b.md"})
      {:ok, _} = Notes.upsert_note(user, vault, %{path: "F3/c.md"})

      {result, scans} =
        with_vault_scan_count(fn ->
          Notes.batch_move_folders(user, vault, [m1.id, m2.id, m3.id], target.id)
        end)

      assert {:ok, %{moved: 3}} = result

      assert scans == 1,
             "expected ONE shared full-vault scan for the whole batch, saw #{scans}"
    end
  end

  # Counts Repo queries against the notes table emitted while `fun` runs,
  # scoped to this test's pid (same shape as billing_test's helper).
  defp with_notes_query_count(fun) do
    count_notes_queries(fun, fn _sql -> true end)
  end

  # Counts only FULL-VAULT scans (fetch_decrypted_live_rows' shape): a SELECT
  # over live rows with no id / folder_hmac / path_hmac narrowing. Marker
  # lookups, conflict checks, and content-by-id fetches don't match, so the
  # count pins exactly the O(vault) N+1 the shared-scan restructure removed.
  defp with_vault_scan_count(fun) do
    count_notes_queries(fun, fn sql ->
      where_clause = sql |> String.split(" WHERE ", parts: 2) |> Enum.at(1, "")

      String.starts_with?(sql, "SELECT") and where_clause =~ ~s("deleted_at" IS NULL) and
        not (where_clause =~ ~s("id")) and not (where_clause =~ "folder_hmac") and
        not (where_clause =~ "path_hmac")
    end)
  end

  defp count_notes_queries(fun, matcher) do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _event, _measurements, %{source: src} = meta, _config ->
        if src == "notes" and self() == test_pid and matcher.(meta[:query] || "") do
          Agent.update(counter, &(&1 + 1))
        end
      end,
      nil
    )

    try do
      result = fun.()
      {result, Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end
end

defmodule Engram.NotesBatchSetBasedTest do
  @moduledoc """
  Set-based batch semantics (#863): one shared seq per delete batch (the
  per-id next_seq! held the vault row lock as a serialization point for the
  whole tenant), and NO broadcasts for batches that fail — the per-id
  composition leaked note_changed events for rolled-back work (documented
  caveat in the old moduledoc; this is the promised fix).
  """
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  test "batch delete stamps ONE shared seq across all tombstones", %{
    user: user,
    vault: vault
  } do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# A"})
    {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "b.md", "content" => "# B"})
    {:ok, n3} = Notes.upsert_note(user, vault, %{"path" => "c.md", "content" => "# C"})

    assert {:ok, %{deleted: 3}} = Notes.batch_delete_notes(user, vault, [n1.id, n2.id, n3.id])

    seqs = for id <- [n1.id, n2.id, n3.id], do: Engram.Fixtures.raw_note_row!(user, id).seq
    assert [_] = Enum.uniq(seqs)
    assert hd(seqs) > n3.seq
  end

  test "failed batch delete emits NO delete broadcasts", %{user: user, vault: vault} do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# A"})

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    assert {:error, {:not_found, _}} =
             Notes.batch_delete_notes(user, vault, [n1.id, Ecto.UUID.generate()])

    refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}, 100

    # And nothing was deleted.
    assert {:ok, _} = Notes.get_note_by_id(user, vault, n1.id)
  end

  test "successful batch delete still broadcasts one delete per note", %{
    user: user,
    vault: vault
  } do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# A"})
    {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "b.md", "content" => "# B"})

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    assert {:ok, %{deleted: 2}} = Notes.batch_delete_notes(user, vault, [n1.id, n2.id])

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: p1}
    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: p2}
    assert Enum.sort([p1["path"], p2["path"]]) == ["a.md", "b.md"]
    assert p1["event_type"] == "delete"
  end

  test "batch delete decrements the notes meter by the batch size", %{
    user: user,
    vault: vault
  } do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# A"})
    {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "b.md", "content" => "# B"})
    before = Engram.UsageMeters.notes_count(user.id)

    assert {:ok, %{deleted: 2}} = Notes.batch_delete_notes(user, vault, [n1.id, n2.id])
    assert Engram.UsageMeters.notes_count(user.id) == before - 2
  end

  # NOTE deliberately absent: a "batch move emits no broadcasts on failure"
  # test would assert a guarantee batch_move_notes does NOT provide — moves
  # still broadcast mid-transaction per item (see its moduledoc caveat), so
  # a multi-item batch that fails late leaks events for rolled-back renames.
  # The after-commit buffer for move/folder ops is the tracked follow-up.

  describe "batch size limits (context boundary)" do
    # Delete/move accept ANY size — real consumers (e2e harness cleanup,
    # test_77 bulk teardown) legitimately send >1000 ids in one request. The
    # actual invariant is ≤500 rows per server TIMESTAMP (the legacy
    # `updated_at >= since` feed re-serves the same page forever if a
    # same-stamp run exceeds the page size — notes_controller.ex
    # changes_server_time), so bulk deletes stamp tombstones in ≤500-row
    # chunks with distinct timestamps instead of rejecting the request.
    test "batch_delete_notes accepts >500 ids and chunk-stamps tombstones", %{
      user: user,
      vault: vault
    } do
      notes = for _ <- 1..501, do: insert(:note, user: user, vault: vault)
      ids = Enum.map(notes, & &1.id)

      assert {:ok, %{deleted: 501}} = Notes.batch_delete_notes(user, vault, ids)

      stamp_runs = stamp_run_sizes(user, ids)

      # STRICTLY fewer than the 500-row legacy page per stamp: the since
      # boundary is inclusive, so a run of EXACTLY page-size wedges too.
      assert length(stamp_runs) >= 2,
             ">500 tombstones must not share one timestamp (legacy-feed wedge)"

      assert Enum.max(stamp_runs) < 500,
             "a same-stamp run of exactly page size (500) re-serves forever"
    end

    test "batch_upsert_notes stamps creates in <500-row timestamp runs", %{
      user: user,
      vault: vault
    } do
      params = for i <- 1..401, do: %{path: "stampchunk/n#{i}.md"}
      assert {:ok, %{results: results}} = Notes.batch_upsert_notes(user, vault, params)
      ids = results |> Enum.filter(&(&1.status == :ok)) |> Enum.map(& &1.id)
      assert length(ids) == 401

      stamp_runs = stamp_run_sizes(user, ids)

      assert length(stamp_runs) >= 2,
             "bulk creates must not all share one updated_at (legacy-feed wedge)"

      assert Enum.max(stamp_runs) < 500
    end

    @tag timeout: 120_000
    test "rename_folder chunk-stamps >500-row cascades (rows + tombstones)", %{
      user: user,
      vault: vault
    } do
      # do_rename_folder stamps EVERY touched row (marker + renamed rows +
      # old-path tombstones) in one cascade; a single shared `now` puts >500
      # rows on one timestamp and wedges the legacy `updated_at >= since`
      # feed exactly like an unchunked batch delete would.
      {:ok, %{results: r1}} =
        Notes.batch_upsert_notes(user, vault, for(i <- 1..500, do: %{path: "BigStamp/n#{i}.md"}))

      {:ok, %{results: r2}} = Notes.batch_upsert_notes(user, vault, [%{path: "BigStamp/n501.md"}])
      assert Enum.all?(r1 ++ r2, &(&1.status == :ok))

      {:ok, _marker} = Notes.create_folder_marker(user, vault, "BigStamp")

      assert {:ok, _} = Notes.rename_folder(user, vault, "BigStamp", "BigStampMoved")

      # Every note row in the vault now carries a rename-time stamp: the
      # marker + 501 renamed rows + 501 tombstones.
      {:ok, ids} =
        Repo.with_tenant(user.id, fn ->
          import Ecto.Query

          Repo.all(from(n in Engram.Notes.Note, where: n.vault_id == ^vault.id, select: n.id))
        end)

      assert length(ids) == 1003

      stamp_runs = stamp_run_sizes(user, ids)

      assert length(stamp_runs) >= 2,
             "a >500-row rename cascade must not share one updated_at (legacy-feed wedge)"

      assert Enum.max(stamp_runs) < 500,
             "a same-stamp run of exactly page size (500) re-serves forever"
    end

    # Upsert keeps a hard cap: each entry costs an encrypt + CRDT merge, so
    # an unbounded request is a real compute-DoS vector, and no client sends
    # >500 (the plugin chunks at ≤100).
    test "batch_upsert_notes rejects more than 500 entries", %{user: user, vault: vault} do
      params = for i <- 1..501, do: %{path: "bulk/n#{i}.md"}
      assert {:error, :batch_too_large} = Notes.batch_upsert_notes(user, vault, params)
    end
  end

  # Sizes of each distinct-updated_at group among the given note ids.
  defp stamp_run_sizes(user, ids) do
    Repo.with_tenant(user.id, fn ->
      import Ecto.Query

      Repo.all(
        from(n in Engram.Notes.Note,
          where: n.id in ^ids,
          group_by: n.updated_at,
          select: count(n.id)
        )
      )
    end)
    |> elem(1)
  end
end
