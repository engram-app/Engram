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
end
