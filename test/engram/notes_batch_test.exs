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

      assert {:error, {:not_found, 999_999}} =
               Notes.batch_move_notes(user, vault, [n1.id], 999_999)

      {:ok, untouched} = Notes.get_note_by_id(user, vault, n1.id)
      assert untouched.path == "a.md"
    end

    test "empty list returns {:ok, %{moved: 0}}", %{user: user, vault: vault} do
      {:ok, target_marker} = Notes.create_folder_marker(user, vault, "Archive")
      assert {:ok, %{moved: 0}} = Notes.batch_move_notes(user, vault, [], target_marker.id)
    end
  end
end
