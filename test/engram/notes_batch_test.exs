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
  end

  # Counts Repo queries against the notes table emitted while `fun` runs,
  # scoped to this test's pid (same shape as billing_test's helper).
  defp with_notes_query_count(fun) do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _event, _measurements, %{source: src}, _config ->
        if src == "notes" and self() == test_pid, do: Agent.update(counter, &(&1 + 1))
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

  defp raw_row(user, id) do
    {:ok, row} =
      Repo.with_tenant(user.id, fn ->
        Repo.get(Notes.Note, id)
      end)

    row
  end

  test "batch delete stamps ONE shared seq across all tombstones", %{
    user: user,
    vault: vault
  } do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# A"})
    {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "b.md", "content" => "# B"})
    {:ok, n3} = Notes.upsert_note(user, vault, %{"path" => "c.md", "content" => "# C"})

    assert {:ok, %{deleted: 3}} = Notes.batch_delete_notes(user, vault, [n1.id, n2.id, n3.id])

    seqs = for id <- [n1.id, n2.id, n3.id], do: raw_row(user, id).seq
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

  test "failed batch move emits NO broadcasts", %{user: user, vault: vault} do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "# A"})
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "sub/a.md", "content" => "# A2"})

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    # a.md → sub/a.md collides; the single-item batch fails and rolls back.
    assert {:error, _} = Notes.batch_move_notes(user, vault, [n1.id], {:path, "sub"})

    refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}, 100
  end
end
