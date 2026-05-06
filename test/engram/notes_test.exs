defmodule Engram.NotesTest do
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    other_user = insert(:user)

    # Allow unlimited vaults so create_vault doesn't hit the billing limit
    insert(:user_override, user: user, overrides: %{"max_vaults" => -1})
    insert(:user_override, user: other_user, overrides: %{"max_vaults" => -1})

    # Phase B reads derive a filter key from the user's DEK. Provision DEK
    # upfront so test users carry encrypted_dek in-struct without a reload.
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, other_user} = Engram.Crypto.ensure_user_dek(other_user)

    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    {:ok, other_vault} = Engram.Vaults.create_vault(other_user, %{name: "Test"})

    %{user: user, other_user: other_user, vault: vault, other_vault: other_vault}
  end

  # ---------------------------------------------------------------------------
  # upsert_note/3
  # ---------------------------------------------------------------------------

  describe "upsert_note/3" do
    test "creates a new note", %{user: user, vault: vault} do
      assert {:ok, note} =
               Notes.upsert_note(user, vault, %{
                 "path" => "Test/Hello.md",
                 "content" => "# Hello\nWorld",
                 "mtime" => 1_709_234_567.0
               })

      assert note.path == "Test/Hello.md"
      assert note.title == "Hello"
      assert note.folder == "Test"
      assert note.content == "# Hello\nWorld"
      assert note.version == 1
      assert is_binary(note.content_hash)
    end

    test "content_hash is HMAC-SHA256 (64-char hex), not legacy MD5",
         %{user: user, vault: vault} do
      content = "# Hash Format Probe\nbody"

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/HashFormat.md",
          "content" => content,
          "mtime" => 1_000.0
        })

      assert String.length(note.content_hash) == 64
      assert note.content_hash =~ ~r/^[0-9a-f]{64}$/

      legacy_md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
      refute note.content_hash == legacy_md5
    end

    test "content_hash differs across users for identical content",
         %{user: user, vault: vault, other_user: other_user, other_vault: other_vault} do
      content = "shared content body"
      attrs = %{"path" => "x.md", "content" => content, "mtime" => 1.0}

      {:ok, n1} = Notes.upsert_note(user, vault, attrs)
      {:ok, n2} = Notes.upsert_note(other_user, other_vault, attrs)

      refute n1.content_hash == n2.content_hash
    end

    test "content_hash deterministic for same user + content",
         %{user: user, vault: vault} do
      content = "deterministic body"

      {:ok, n1} =
        Notes.upsert_note(user, vault, %{
          "path" => "a.md",
          "content" => content,
          "mtime" => 1.0
        })

      {:ok, n2} =
        Notes.upsert_note(user, vault, %{
          "path" => "b.md",
          "content" => content,
          "mtime" => 2.0
        })

      assert n1.content_hash == n2.content_hash
    end

    test "upserts existing note, increments version", %{user: user, vault: vault} do
      {:ok, v1} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/File.md",
          "content" => "# Original",
          "mtime" => 1_000.0
        })

      {:ok, v2} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/File.md",
          "content" => "# Updated",
          "mtime" => 2_000.0
        })

      assert v2.id == v1.id
      assert v2.version == 2
      assert v2.title == "Updated"
    end

    test "extracts tags from frontmatter", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/Tagged.md",
          "content" => "---\ntags: [health, omega]\n---\n# Tagged\nBody",
          "mtime" => 1_000.0
        })

      assert note.tags == ["health", "omega"]
    end

    test "sanitizes path before storing", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/Why do I resist?.md",
          "content" => "# Why",
          "mtime" => 1_000.0
        })

      assert note.path == "Test/Why do I resist.md"
    end

    test "computes content_hash via HMAC-SHA256", %{user: user, vault: vault} do
      content = "# Hello\nWorld"

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/A.md",
          "content" => content,
          "mtime" => 1_000.0
        })

      {:ok, key} = Engram.Crypto.dek_content_hash_key(user)
      expected = Engram.Crypto.hmac_content_hash(key, content)
      assert note.content_hash == expected
    end

    test "handles empty content", %{user: user, vault: vault} do
      assert {:ok, note} =
               Notes.upsert_note(user, vault, %{
                 "path" => "Test/Empty.md",
                 "content" => "",
                 "mtime" => 1_000.0
               })

      assert note.path == "Test/Empty.md"
    end

    test "coerces nil content to empty string", %{user: user, vault: vault} do
      assert {:ok, note} =
               Notes.upsert_note(user, vault, %{
                 "path" => "Test/NilContent.md",
                 "content" => nil,
                 "mtime" => 1_000.0
               })

      assert note.content == ""
      assert is_binary(note.content_hash)
    end

    test "coerces missing content key to empty string", %{user: user, vault: vault} do
      assert {:ok, note} =
               Notes.upsert_note(user, vault, %{
                 "path" => "Test/NoContent.md",
                 "mtime" => 1_000.0
               })

      assert note.content == ""
      assert is_binary(note.content_hash)
    end

    test "returns error for missing path", %{vault: vault} do
      user = insert(:user)
      insert(:user_override, user: user, overrides: %{"max_vaults" => -1})

      assert {:error, changeset} =
               Notes.upsert_note(user, vault, %{"content" => "# Hello", "mtime" => 1_000.0})

      assert errors_on(changeset).path
    end
  end

  # ---------------------------------------------------------------------------
  # Note.changeset/2 defense-in-depth
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # get_note/3
  # ---------------------------------------------------------------------------

  describe "get_note/3" do
    test "returns note for correct user", %{user: user, vault: vault} do
      {:ok, created} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/Readable.md",
          "content" => "# Readable",
          "mtime" => 1_000.0
        })

      assert {:ok, found} = Notes.get_note(user, vault, "Test/Readable.md")
      assert found.id == created.id
    end

    test "returns not_found for wrong user", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Private.md",
        "content" => "# Private",
        "mtime" => 1_000.0
      })

      assert {:error, :not_found} = Notes.get_note(other_user, other_vault, "Test/Private.md")
    end

    test "returns not_found for deleted note", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/ToDelete.md",
        "content" => "# Delete me",
        "mtime" => 1_000.0
      })

      Notes.delete_note(user, vault, "Test/ToDelete.md")

      assert {:error, :not_found} = Notes.get_note(user, vault, "Test/ToDelete.md")
    end

    test "returns not_found for nonexistent path", %{user: user, vault: vault} do
      assert {:error, :not_found} = Notes.get_note(user, vault, "Nope/Missing.md")
    end

    # B.2.6 tamper-plaintext tests retired with B.3 — plaintext path/folder/
    # tags columns no longer exist, so a tamper is impossible. Decryption
    # via path_hmac is the only lookup path now.
  end

  # ---------------------------------------------------------------------------
  # delete_note/3
  # ---------------------------------------------------------------------------

  describe "delete_note/3" do
    test "soft-deletes a note", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Bye.md",
        "content" => "# Bye",
        "mtime" => 1_000.0
      })

      assert :ok = Notes.delete_note(user, vault, "Test/Bye.md")
      assert {:error, :not_found} = Notes.get_note(user, vault, "Test/Bye.md")
    end

    test "is idempotent for nonexistent note", %{user: user, vault: vault} do
      assert :ok = Notes.delete_note(user, vault, "Fake/Note.md")
    end

    test "does not affect other user's notes", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Shared Path.md",
        "content" => "# User A note",
        "mtime" => 1_000.0
      })

      assert :ok = Notes.delete_note(other_user, other_vault, "Test/Shared Path.md")
      # User A's note should still exist
      assert {:ok, _} = Notes.get_note(user, vault, "Test/Shared Path.md")
    end
  end

  # ---------------------------------------------------------------------------
  # list_changes/3
  # ---------------------------------------------------------------------------

  describe "list_changes/3" do
    test "returns notes updated since timestamp", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/Recent.md",
          "content" => "# Recent",
          "mtime" => 1_000.0
        })

      past = DateTime.add(note.updated_at, -60, :second)
      {:ok, changes} = Notes.list_changes(user, vault, past)

      assert Enum.any?(changes, &(&1.path == "Test/Recent.md"))
    end

    test "includes soft-deleted notes with deleted flag", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Deleted.md",
        "content" => "# Will be deleted",
        "mtime" => 1_000.0
      })

      Notes.delete_note(user, vault, "Test/Deleted.md")

      past = ~U[2020-01-01 00:00:00Z]
      {:ok, changes} = Notes.list_changes(user, vault, past)

      deleted = Enum.find(changes, &(&1.path == "Test/Deleted.md"))
      assert deleted != nil
      assert deleted.deleted == true
    end

    test "excludes notes from other users", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      Notes.upsert_note(other_user, other_vault, %{
        "path" => "Test/Other.md",
        "content" => "# Other user",
        "mtime" => 1_000.0
      })

      past = ~U[2020-01-01 00:00:00Z]
      {:ok, changes} = Notes.list_changes(user, vault, past)

      refute Enum.any?(changes, &(&1.path == "Test/Other.md"))
    end

    test "returns empty list when no changes since timestamp", %{user: user, vault: vault} do
      {:ok, changes} = Notes.list_changes(user, vault, ~U[2099-01-01 00:00:00Z])
      assert changes == []
    end

    test "includes changes when since equals updated_at (>= not >)", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/SameSecond.md",
          "content" => "# Same second test",
          "mtime" => 1_000.0
        })

      # The server_time returned to clients is truncated to seconds.
      # Changes must still appear when queried with that truncated value.
      # This guards against > vs >= regressions in the list_changes query.
      since_truncated = DateTime.truncate(note.updated_at, :second)
      {:ok, changes} = Notes.list_changes(user, vault, since_truncated)

      assert Enum.any?(changes, &(&1.path == "Test/SameSecond.md")),
             "Changes in the same second as truncated server_time must be included"
    end
  end

  # ---------------------------------------------------------------------------
  # list_tags/2
  # ---------------------------------------------------------------------------

  describe "list_tags/2" do
    test "returns unique tags across user's notes", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "A.md",
        "content" => "---\ntags: [health, fitness]\n---",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "B.md",
        "content" => "---\ntags: [health, nutrition]\n---",
        "mtime" => 1_000.0
      })

      {:ok, tags} = Notes.list_tags(user, vault)
      assert "health" in tags
      assert "fitness" in tags
      assert "nutrition" in tags
      # health appears in 2 notes but should only show once
      assert Enum.count(tags, &(&1 == "health")) == 1
    end

    test "excludes tags from other users", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      Notes.upsert_note(other_user, other_vault, %{
        "path" => "A.md",
        "content" => "---\ntags: [secret]\n---",
        "mtime" => 1_000.0
      })

      {:ok, tags} = Notes.list_tags(user, vault)
      refute "secret" in tags
    end
  end

  # ---------------------------------------------------------------------------
  # list_folders/2
  # ---------------------------------------------------------------------------

  describe "list_folders/2" do
    test "returns unique folders for user", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Folder A/Note.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "Folder B/Note.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "Folder A/Other.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      {:ok, folders} = Notes.list_folders(user, vault)
      assert "Folder A" in folders
      assert "Folder B" in folders
      assert Enum.count(folders, &(&1 == "Folder A")) == 1
    end

    test "excludes empty folder (root-level notes)", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{"path" => "Root.md", "content" => "x", "mtime" => 1_000.0})

      {:ok, folders} = Notes.list_folders(user, vault)
      refute "" in folders
    end

    test "excludes other users folders", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      Notes.upsert_note(other_user, other_vault, %{
        "path" => "Private Folder/Note.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      {:ok, folders} = Notes.list_folders(user, vault)
      refute "Private Folder" in folders
    end

    test "list_notes_in_folder filters by folder_hmac",
         %{user: user, vault: vault} do
      {:ok, created} =
        Notes.upsert_note(user, vault, %{
          "path" => "Real/Note.md",
          "content" => "x"
        })

      assert {:ok, [note]} = Notes.list_notes_in_folder(user, vault, "Real")
      assert note.id == created.id
      assert note.folder == "Real"
    end

    test "list_folders groups by folder_hmac and decrypts ciphertext",
         %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Real/Note.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      {:ok, folders} = Notes.list_folders(user, vault)
      assert "Real" in folders
    end
  end

  # ---------------------------------------------------------------------------
  # rename_note/4
  # ---------------------------------------------------------------------------

  describe "rename_note/4" do
    test "renames note to new path", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Original.md",
        "content" => "# Original",
        "mtime" => 1_000.0
      })

      assert {:ok, renamed} =
               Notes.rename_note(user, vault, "Test/Original.md", "Test/Renamed.md")

      assert renamed.path == "Test/Renamed.md"
      assert renamed.title == "Original"
    end

    test "updates folder when path moves to different folder", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Old Folder/Note.md",
        "content" => "# Note",
        "mtime" => 1_000.0
      })

      {:ok, renamed} = Notes.rename_note(user, vault, "Old Folder/Note.md", "New Folder/Note.md")
      assert renamed.folder == "New Folder"
    end

    test "sanitizes new path", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Clean.md",
        "content" => "# Clean",
        "mtime" => 1_000.0
      })

      {:ok, renamed} = Notes.rename_note(user, vault, "Test/Clean.md", "Test/Dirty?.md")
      assert renamed.path == "Test/Dirty.md"
    end

    test "returns not_found for nonexistent note", %{user: user, vault: vault} do
      assert {:error, :not_found} =
               Notes.rename_note(user, vault, "Nope/Missing.md", "Nope/New.md")
    end

    test "does not rename other user's note", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Mine.md",
        "content" => "# Mine",
        "mtime" => 1_000.0
      })

      assert {:error, :not_found} =
               Notes.rename_note(other_user, other_vault, "Test/Mine.md", "Test/Stolen.md")
    end
  end

  # ---------------------------------------------------------------------------
  # list_tags_with_counts/2
  # ---------------------------------------------------------------------------

  describe "list_tags_with_counts/2" do
    test "returns tags with correct counts", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "A.md",
        "content" => "---\ntags: [health, fitness]\n---",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "B.md",
        "content" => "---\ntags: [health, nutrition]\n---",
        "mtime" => 1_000.0
      })

      {:ok, tags} = Notes.list_tags_with_counts(user, vault)
      health = Enum.find(tags, &(&1.name == "health"))
      fitness = Enum.find(tags, &(&1.name == "fitness"))
      nutrition = Enum.find(tags, &(&1.name == "nutrition"))

      assert health.count == 2
      assert fitness.count == 1
      assert nutrition.count == 1
    end

    test "returns empty list when no notes", %{user: user, vault: vault} do
      {:ok, tags} = Notes.list_tags_with_counts(user, vault)
      assert tags == []
    end

    test "excludes soft-deleted notes", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Deleted.md",
        "content" => "---\ntags: [ghost]\n---",
        "mtime" => 1_000.0
      })

      Notes.delete_note(user, vault, "Deleted.md")

      {:ok, tags} = Notes.list_tags_with_counts(user, vault)
      refute Enum.any?(tags, &(&1.name == "ghost"))
    end

    test "excludes other user's tags", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      Notes.upsert_note(other_user, other_vault, %{
        "path" => "Secret.md",
        "content" => "---\ntags: [secret]\n---",
        "mtime" => 1_000.0
      })

      {:ok, tags} = Notes.list_tags_with_counts(user, vault)
      refute Enum.any?(tags, &(&1.name == "secret"))
    end
  end

  # ---------------------------------------------------------------------------
  # list_folders_with_counts/2
  # ---------------------------------------------------------------------------

  describe "list_folders_with_counts/2" do
    test "returns folders with correct counts", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Health/Note1.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "Health/Note2.md",
        "content" => "y",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "Work/Note1.md",
        "content" => "z",
        "mtime" => 1_000.0
      })

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      health = Enum.find(folders, &(&1.folder == "Health"))
      work = Enum.find(folders, &(&1.folder == "Work"))

      assert health.count == 2
      assert work.count == 1
    end

    test "includes root folder count", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{"path" => "Root.md", "content" => "x", "mtime" => 1_000.0})

      Notes.upsert_note(user, vault, %{
        "path" => "Health/Note.md",
        "content" => "y",
        "mtime" => 1_000.0
      })

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      # Root notes have folder = nil or ""
      root = Enum.find(folders, &(&1.folder == "" || &1.folder == nil))
      assert root != nil
      assert root.count == 1
    end

    test "returns empty list when no notes", %{user: user, vault: vault} do
      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      assert folders == []
    end

    test "groups by folder_hmac and decrypts ciphertext",
         %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Health/A.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "Health/B.md",
        "content" => "y",
        "mtime" => 1_000.0
      })

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      health = Enum.find(folders, &(&1.folder == "Health"))
      assert health
      assert health.count == 2
    end

    test "excludes soft-deleted notes", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Ghost/Note.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      Notes.delete_note(user, vault, "Ghost/Note.md")

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      refute Enum.any?(folders, &(&1.folder == "Ghost"))
    end
  end

  # ---------------------------------------------------------------------------
  # list_notes_in_folder/3
  # ---------------------------------------------------------------------------

  describe "list_notes_in_folder/3" do
    test "returns notes in a specific folder", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Health/Note1.md",
        "content" => "# A",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "Health/Note2.md",
        "content" => "# B",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "Work/Note1.md",
        "content" => "# C",
        "mtime" => 1_000.0
      })

      {:ok, notes} = Notes.list_notes_in_folder(user, vault, "Health")
      assert length(notes) == 2
      paths = Enum.map(notes, & &1.path)
      assert "Health/Note1.md" in paths
      assert "Health/Note2.md" in paths
    end

    test "returns root-level notes with empty string", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Root.md",
        "content" => "# Root",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "Health/Note.md",
        "content" => "# Health",
        "mtime" => 1_000.0
      })

      {:ok, notes} = Notes.list_notes_in_folder(user, vault, "")
      assert length(notes) == 1
      assert hd(notes).path == "Root.md"
    end

    test "returns empty list for non-existent folder", %{user: user, vault: vault} do
      {:ok, notes} = Notes.list_notes_in_folder(user, vault, "Nonexistent")
      assert notes == []
    end

    test "excludes soft-deleted notes", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Health/Deleted.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      Notes.delete_note(user, vault, "Health/Deleted.md")

      {:ok, notes} = Notes.list_notes_in_folder(user, vault, "Health")
      assert notes == []
    end

    test "excludes other user's notes", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      Notes.upsert_note(other_user, other_vault, %{
        "path" => "Health/Secret.md",
        "content" => "x",
        "mtime" => 1_000.0
      })

      {:ok, notes} = Notes.list_notes_in_folder(user, vault, "Health")
      assert notes == []
    end
  end

  # ---------------------------------------------------------------------------
  # upsert_note/2 — Phase B dual-write
  # ---------------------------------------------------------------------------

  describe "upsert_note/2 — Phase B dual-write" do
    setup do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)
      %{user: user, vault: vault}
    end

    test "populates path_hmac, path_ciphertext, path_nonce", %{user: user, vault: vault} do
      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "projects/q3/secret.md",
          "content" => "hello"
        })

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected_hmac = Engram.Crypto.hmac_field(filter_key, "projects/q3/secret.md")

      assert note.path_hmac == expected_hmac
      assert is_binary(note.path_ciphertext)
      assert byte_size(note.path_nonce) == 12
    end

    test "populates folder_hmac, folder_ciphertext, folder_nonce", %{user: user, vault: vault} do
      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "projects/q3/secret.md",
          "content" => "hello"
        })

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected_hmac = Engram.Crypto.hmac_field(filter_key, "projects/q3")

      assert note.folder_hmac == expected_hmac
      assert is_binary(note.folder_ciphertext)
      assert byte_size(note.folder_nonce) == 12
    end

    test "populates one tags_hmac entry per tag", %{user: user, vault: vault} do
      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "x.md",
          "content" => "---\ntags: [legal, client-acme]\n---\ny"
        })

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)

      expected = [
        Engram.Crypto.hmac_field(filter_key, "legal"),
        Engram.Crypto.hmac_field(filter_key, "client-acme")
      ]

      assert Enum.sort(note.tags_hmac) == Enum.sort(expected)
    end

    test "tags_hmac is empty array when no tags", %{user: user, vault: vault} do
      {:ok, note} = Engram.Notes.upsert_note(user, vault, %{"path" => "x.md", "content" => "y"})
      assert note.tags_hmac == []
    end

    test "still writes plaintext path/folder/tags (dual-write)", %{user: user, vault: vault} do
      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "a/b/c.md",
          "content" => "---\ntags: [t1]\n---\ny"
        })

      assert note.path == "a/b/c.md"
      assert note.folder == "a/b"
      assert note.tags == ["t1"]
    end

    test "upsert_note provisions DEK and writes Phase B fields even when user starts with no DEK" do
      # Insert user without DEK — Phase B must NOT silently skip
      raw_user =
        Engram.Repo.insert!(%Engram.Accounts.User{
          email: "no-dek-#{System.unique_integer()}@test.com",
          display_name: "No DEK",
          external_id: nil
        })

      vault = insert(:vault, user: raw_user)

      assert {:ok, note} =
               Engram.Notes.upsert_note(raw_user, vault, %{
                 "path" => "secure/file.md",
                 "content" => "hello"
               })

      assert is_binary(note.path_hmac),
             "path_hmac must be set — Phase B must not silently skip for no-DEK user"

      assert is_binary(note.path_ciphertext)
      assert byte_size(note.path_nonce) == 12
    end
  end

  # ---------------------------------------------------------------------------
  # rename_folder/4
  # ---------------------------------------------------------------------------

  describe "rename_folder/4" do
    test "renames folder for all notes in it", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Old/Note1.md",
        "content" => "# A",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "Old/Note2.md",
        "content" => "# B",
        "mtime" => 1_000.0
      })

      assert {:ok, 2} = Notes.rename_folder(user, vault, "Old", "New")

      {:ok, notes} = Notes.list_notes_in_folder(user, vault, "New")
      assert length(notes) == 2
      paths = Enum.map(notes, & &1.path)
      assert "New/Note1.md" in paths
      assert "New/Note2.md" in paths

      {:ok, old_notes} = Notes.list_notes_in_folder(user, vault, "Old")
      assert old_notes == []
    end

    test "renames subfolder notes too", %{user: user, vault: vault} do
      Notes.upsert_note(user, vault, %{
        "path" => "Parent/Child/Note.md",
        "content" => "# Deep",
        "mtime" => 1_000.0
      })

      Notes.upsert_note(user, vault, %{
        "path" => "Parent/Note.md",
        "content" => "# Shallow",
        "mtime" => 1_000.0
      })

      assert {:ok, 2} = Notes.rename_folder(user, vault, "Parent", "Renamed")

      assert {:ok, _} = Notes.get_note(user, vault, "Renamed/Note.md")
      assert {:ok, _} = Notes.get_note(user, vault, "Renamed/Child/Note.md")
      assert {:error, :not_found} = Notes.get_note(user, vault, "Parent/Note.md")
    end

    test "returns 0 when folder has no notes", %{user: user, vault: vault} do
      assert {:ok, 0} = Notes.rename_folder(user, vault, "Empty", "StillEmpty")
    end

    test "does not affect other user's notes", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      Notes.upsert_note(other_user, other_vault, %{
        "path" => "Shared/Note.md",
        "content" => "# Other",
        "mtime" => 1_000.0
      })

      assert {:ok, 0} = Notes.rename_folder(user, vault, "Shared", "Renamed")

      # Other user's note untouched
      assert {:ok, _} = Notes.get_note(other_user, other_vault, "Shared/Note.md")
    end

    test "recomputes path_hmac and folder_hmac for the new path/folder",
         %{user: user, vault: vault} do
      {:ok, before} =
        Notes.upsert_note(user, vault, %{
          "path" => "Old/Note.md",
          "content" => "# Old",
          "mtime" => 1_000.0
        })

      {:ok, 1} = Notes.rename_folder(user, vault, "Old", "New")

      {:ok, after_row} =
        Repo.with_tenant(user.id, fn ->
          Repo.one(from(n in Engram.Notes.Note, where: n.id == ^before.id))
        end)

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      assert after_row.path_hmac == Engram.Crypto.hmac_field(filter_key, "New/Note.md")
      assert after_row.folder_hmac == Engram.Crypto.hmac_field(filter_key, "New")
      refute after_row.path_hmac == before.path_hmac
      refute after_row.folder_hmac == before.folder_hmac
    end
  end

  # ---------------------------------------------------------------------------
  # rename_note/4 path_hmac regression
  # ---------------------------------------------------------------------------

  describe "rename_note/4 phase B sync" do
    test "recomputes path_hmac and folder_hmac for the new path/folder",
         %{user: user, vault: vault} do
      {:ok, before} =
        Notes.upsert_note(user, vault, %{
          "path" => "Folder/Old.md",
          "content" => "# Old",
          "mtime" => 1_000.0
        })

      {:ok, _} = Notes.rename_note(user, vault, "Folder/Old.md", "Folder/New.md")

      {:ok, after_row} =
        Repo.with_tenant(user.id, fn ->
          Repo.one(from(n in Engram.Notes.Note, where: n.id == ^before.id))
        end)

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      assert after_row.path_hmac == Engram.Crypto.hmac_field(filter_key, "Folder/New.md")
      refute after_row.path_hmac == before.path_hmac
    end
  end
end
