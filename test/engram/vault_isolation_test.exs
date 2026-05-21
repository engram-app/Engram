defmodule Engram.VaultIsolationTest do
  @moduledoc """
  Vault isolation tests — proves that data in vault A is NOT visible when
  querying through vault B for the same user, and vice versa.
  """
  use Engram.DataCase, async: true

  alias Engram.{Notes, Vaults}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})

    # Phase B reads derive a filter key from the user's DEK — provision upfront.
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)

    {:ok, vault_a} = Vaults.create_vault(user, %{name: "Personal"})
    {:ok, vault_b} = Vaults.create_vault(user, %{name: "Work"})

    %{user: user, vault_a: vault_a, vault_b: vault_b}
  end

  # ---------------------------------------------------------------------------
  # 1. Note in vault A not visible from vault B
  # ---------------------------------------------------------------------------

  describe "note isolation across vaults" do
    test "note in vault_a is not visible from vault_b", %{
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    } do
      {:ok, _} =
        Notes.upsert_note(user, vault_a, %{
          "path" => "test.md",
          "content" => "# Only in A",
          "mtime" => 1_000.0
        })

      assert {:error, :not_found} = Notes.get_note(user, vault_b, "test.md")
    end

    test "note in vault_b is not visible from vault_a", %{
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    } do
      {:ok, _} =
        Notes.upsert_note(user, vault_b, %{
          "path" => "test.md",
          "content" => "# Only in B",
          "mtime" => 1_000.0
        })

      assert {:error, :not_found} = Notes.get_note(user, vault_a, "test.md")
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Same path in both vaults are independent
  # ---------------------------------------------------------------------------

  describe "same path independence" do
    test "same path in both vaults holds independent content", %{
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    } do
      {:ok, _} =
        Notes.upsert_note(user, vault_a, %{
          "path" => "readme.md",
          "content" => "Personal",
          "mtime" => 1_000.0
        })

      {:ok, _} =
        Notes.upsert_note(user, vault_b, %{
          "path" => "readme.md",
          "content" => "Work",
          "mtime" => 1_000.0
        })

      {:ok, note_a} = Notes.get_note(user, vault_a, "readme.md")
      {:ok, note_b} = Notes.get_note(user, vault_b, "readme.md")

      assert note_a.content == "Personal"
      assert note_b.content == "Work"
      refute note_a.id == note_b.id
    end
  end

  # ---------------------------------------------------------------------------
  # 3. list_changes scoped to vault
  # ---------------------------------------------------------------------------

  describe "list_changes/3 vault scoping" do
    test "list_changes for vault_a excludes vault_b notes", %{
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    } do
      past = ~U[2020-01-01 00:00:00Z]

      {:ok, _} =
        Notes.upsert_note(user, vault_a, %{
          "path" => "vault-a-note.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      {:ok, _} =
        Notes.upsert_note(user, vault_b, %{
          "path" => "vault-b-note.md",
          "content" => "# B",
          "mtime" => 1_000.0
        })

      {:ok, changes_a} = Notes.list_changes(user, vault_a, past)
      paths_a = Enum.map(changes_a, & &1.path)

      assert "vault-a-note.md" in paths_a
      refute "vault-b-note.md" in paths_a
    end

    test "list_changes for vault_b excludes vault_a notes", %{
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    } do
      past = ~U[2020-01-01 00:00:00Z]

      {:ok, _} =
        Notes.upsert_note(user, vault_a, %{
          "path" => "vault-a-note.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      {:ok, _} =
        Notes.upsert_note(user, vault_b, %{
          "path" => "vault-b-note.md",
          "content" => "# B",
          "mtime" => 1_000.0
        })

      {:ok, changes_b} = Notes.list_changes(user, vault_b, past)
      paths_b = Enum.map(changes_b, & &1.path)

      assert "vault-b-note.md" in paths_b
      refute "vault-a-note.md" in paths_b
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Tags scoped to vault
  # ---------------------------------------------------------------------------

  describe "list_tags/2 vault scoping" do
    test "tags from vault_a are not visible in vault_b", %{
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    } do
      Notes.upsert_note(user, vault_a, %{
        "path" => "a.md",
        "content" => "---\ntags: [personal]\n---",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault_b, %{
        "path" => "b.md",
        "content" => "---\ntags: [work]\n---",
        "mtime" => 1_000.0
      })

      {:ok, tags_a} = Notes.list_tags(user, vault_a)
      {:ok, tags_b} = Notes.list_tags(user, vault_b)

      assert "personal" in tags_a
      refute "work" in tags_a

      assert "work" in tags_b
      refute "personal" in tags_b
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Folders scoped to vault
  # ---------------------------------------------------------------------------

  describe "list_folders/2 vault scoping" do
    test "folders from vault_a are not visible in vault_b", %{
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    } do
      Notes.upsert_note(user, vault_a, %{
        "path" => "journal/entry.md",
        "content" => "# Entry",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault_b, %{
        "path" => "projects/spec.md",
        "content" => "# Spec",
        "mtime" => 1_000.0
      })

      {:ok, folders_a} = Notes.list_folders(user, vault_a)
      {:ok, folders_b} = Notes.list_folders(user, vault_b)

      assert "journal" in folders_a
      refute "projects" in folders_a

      assert "projects" in folders_b
      refute "journal" in folders_b
    end
  end

  # ---------------------------------------------------------------------------
  # 6. list_notes_in_folder scoped to vault
  # ---------------------------------------------------------------------------

  describe "list_notes_in_folder/3 vault scoping" do
    test "same folder name in both vaults returns only the correct vault's notes", %{
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    } do
      Notes.upsert_note(user, vault_a, %{
        "path" => "shared/note-from-a.md",
        "content" => "# A",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault_b, %{
        "path" => "shared/note-from-b.md",
        "content" => "# B",
        "mtime" => 1_000.0
      })

      {:ok, notes_a} = Notes.list_notes_in_folder(user, vault_a, "shared")
      {:ok, notes_b} = Notes.list_notes_in_folder(user, vault_b, "shared")

      paths_a = Enum.map(notes_a, & &1.path)
      paths_b = Enum.map(notes_b, & &1.path)

      assert paths_a == ["shared/note-from-a.md"]
      assert paths_b == ["shared/note-from-b.md"]
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Delete in one vault doesn't affect another
  # ---------------------------------------------------------------------------

  describe "delete_note/3 vault isolation" do
    test "deleting a note in vault_a does not delete the same path in vault_b", %{
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    } do
      Notes.upsert_note(user, vault_a, %{
        "path" => "shared.md",
        "content" => "# In A",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault_b, %{
        "path" => "shared.md",
        "content" => "# In B",
        "mtime" => 1_000.0
      })

      :ok = Notes.delete_note(user, vault_a, "shared.md")

      assert {:error, :not_found} = Notes.get_note(user, vault_a, "shared.md")
      assert {:ok, note_b} = Notes.get_note(user, vault_b, "shared.md")
      assert note_b.content == "# In B"
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Rename in one vault doesn't affect another
  # ---------------------------------------------------------------------------

  describe "rename_note/4 vault isolation" do
    test "renaming a note in vault_a does not affect the same path in vault_b", %{
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    } do
      Notes.upsert_note(user, vault_a, %{
        "path" => "original.md",
        "content" => "# A",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault_b, %{
        "path" => "original.md",
        "content" => "# B",
        "mtime" => 1_000.0
      })

      {:ok, _} = Notes.rename_note(user, vault_a, "original.md", "renamed.md")

      # vault_a: old path gone, new path exists
      assert {:error, :not_found} = Notes.get_note(user, vault_a, "original.md")
      assert {:ok, _} = Notes.get_note(user, vault_a, "renamed.md")

      # vault_b: original path still intact
      assert {:ok, note_b} = Notes.get_note(user, vault_b, "original.md")
      assert note_b.content == "# B"
    end
  end
end
