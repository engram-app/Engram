defmodule Engram.NotesTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes

  setup do
    user = insert(:user)
    other_user = insert(:user)

    # Allow unlimited vaults so create_vault doesn't hit the billing limit
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    insert(:user_limit_override, user: other_user, key: "vaults_cap", value: %{"v" => -1})

    # Phase B reads derive a filter key from the user's DEK. Provision DEK
    # upfront so test users carry encrypted_dek in-struct without a reload.
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, other_user} = Engram.Crypto.ensure_user_dek(other_user)

    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    {:ok, other_vault} = Engram.Vaults.create_vault(other_user, %{name: "Test"})

    %{user: user, other_user: other_user, vault: vault, other_vault: other_vault}
  end

  # ---------------------------------------------------------------------------
  # write-rejection / divergence logging — silent drops are the worst incident
  # class; every reject/rewrite/conflict must leave a queryable server trace.
  # ---------------------------------------------------------------------------

  describe "write-rejection logging" do
    import ExUnit.CaptureLog

    test "logs when the sanitizer rewrites the path (silent divergence risk)", %{
      user: user,
      vault: vault
    } do
      log =
        capture_log(fn ->
          {:ok, note} =
            Notes.upsert_note(user, vault, %{
              "path" => "Test/Dirty?.md",
              "content" => "# Dirty",
              "mtime" => 1_000.0
            })

          assert note.path == "Test/Dirty.md"
        end)

      assert log =~ "note_path_rewritten"
      assert log =~ "user_id=#{user.id}"
      assert log =~ "note_id="
    end

    test "does NOT log a rewrite when the path is already clean", %{user: user, vault: vault} do
      log =
        capture_log(fn ->
          {:ok, _} =
            Notes.upsert_note(user, vault, %{
              "path" => "Test/Clean.md",
              "content" => "# Clean",
              "mtime" => 1_000.0
            })
        end)

      refute log =~ "note_path_rewritten"
    end

    test "logs a summary when a batch upsert partially rejects entries", %{
      user: user,
      vault: vault
    } do
      log =
        capture_log(fn ->
          {:ok, %{results: _}} =
            Notes.batch_upsert_notes(user, vault, [
              %{"path" => "Batch/A.md", "content" => "# A", "mtime" => 1_000.0},
              # Duplicate sanitized path within the batch → rejected entry.
              %{"path" => "Batch/A.md", "content" => "# A dup", "mtime" => 1_001.0}
            ])
        end)

      assert log =~ "note_batch_partial_reject"
      assert log =~ "user_id=#{user.id}"
      assert log =~ "failed_count=1"
      assert log =~ "total_count=2"
    end

    test "#727: scrubs invalid UTF-8 on the batch write path", %{user: user, vault: vault} do
      bad = "# Title\n\nPRs #71" <> <<0xE2>> <> "#85"

      assert {:ok, %{results: [%{status: :ok}]}} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "Batch/Bad.md", "content" => bad, "mtime" => 1_000.0}
               ])

      assert {:ok, note} = Notes.get_note(user, vault, "Batch/Bad.md")
      assert String.valid?(note.content)
      assert {:ok, _} = Jason.encode(%{content: note.content})
      assert note.content =~ "PRs #71"
    end
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

    test "#727: scrubs invalid UTF-8 in content before storing", %{user: user, vault: vault} do
      # A `–` (U+2013) truncated to its lead byte — invalid UTF-8 that would
      # otherwise persist through bytea ciphertext and crash Jason downstream.
      bad = "# Title\n\nPRs #71" <> <<0xE2>> <> "#85"

      assert {:ok, note} =
               Notes.upsert_note(user, vault, %{
                 "path" => "Test/BadBytes.md",
                 "content" => bad,
                 "mtime" => 1_000.0
               })

      assert String.valid?(note.content)
      assert {:ok, _} = Jason.encode(%{content: note.content})
      assert note.content =~ "PRs #71"
    end

    test "#739: emits a write-boundary scrub telemetry event on invalid UTF-8",
         %{user: user, vault: vault} do
      handler = "notes-write-scrub-#{inspect(make_ref())}"

      :telemetry.attach(
        handler,
        [:engram, :notes, :utf8_scrub],
        fn _e, meas, meta, pid -> send(pid, {:scrub, meas, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _} =
               Notes.upsert_note(user, vault, %{
                 "path" => "Test/BadBytes2.md",
                 "content" => "# T\n\nx" <> <<0xE2>> <> "y",
                 "mtime" => 1_000.0
               })

      assert_receive {:scrub, %{count: 1}, %{boundary: :write}}
    end

    test "#741: a multibyte char after a numeric #tag never stores invalid-UTF-8 tags at rest",
         %{user: user, vault: vault} do
      # Valid content `x #628– y` (en-dash) used to make extract_tags emit a
      # byte-sliced `628`+0xE2 tag that persisted as invalid UTF-8 — the prod
      # source of corrupt tags. Assert the STORED tags are valid at rest.
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/EnDashTag.md",
          "content" => "x #628" <> <<0xE2, 0x80, 0x93>> <> " y",
          "mtime" => 1.0
        })

      {:ok, raw} =
        Engram.Repo.with_tenant(user.id, fn -> Engram.Repo.get!(Engram.Notes.Note, note.id) end)

      {:ok, dec} = Engram.Crypto.decrypt_note_fields_unscrubbed(raw, user)

      assert Enum.all?(dec.tags, &String.valid?/1)
    end

    test "#738: note_changed broadcast payload is JSON-safe when content holds invalid UTF-8",
         %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      bad = "# Title\n\nbroadcast" <> <<0xE2>> <> "payload"

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/Broadcast.md",
          "content" => bad,
          "mtime" => 1.0
        })

      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: payload}

      # The whole payload is what crashed Phoenix.PubSub/Jason on #738 before the
      # boundary scrubs. Assert the egress payload — not just the stored row — is
      # JSON-encodable and every string field is valid UTF-8.
      assert {:ok, _} = Jason.encode(payload)
      assert String.valid?(payload["content"])
      assert String.valid?(payload["title"])
      assert payload["content"] =~ "broadcast"
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
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})

      assert {:error, changeset} =
               Notes.upsert_note(user, vault, %{"content" => "# Hello", "mtime" => 1_000.0})

      assert errors_on(changeset).path
    end

    test "upsert with same path as a folder marker creates a separate note row",
         %{user: user, vault: vault} do
      {:ok, _marker} = Notes.create_folder_marker(user, vault, "Both")

      assert {:ok, note} =
               Notes.upsert_note(user, vault, %{
                 "path" => "Both",
                 "content" => "I am extensionless",
                 "mtime" => 1.0
               })

      assert note.kind == "note"
      assert note.path == "Both"

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      assert Enum.any?(folders, &(&1.folder == "Both"))
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
  # get_or_bootstrap_note/3
  # ---------------------------------------------------------------------------

  describe "get_or_bootstrap_note/3" do
    test "creates an empty note when the path does not exist yet", %{user: user, vault: vault} do
      assert {:error, :not_found} = Notes.get_note(user, vault, "Bootstrap/New.md")

      assert {:ok, note} = Notes.get_or_bootstrap_note(user, vault, "Bootstrap/New.md")
      assert note.path == "Bootstrap/New.md"
      assert note.content == ""

      # It is now persisted and retrievable.
      assert {:ok, again} = Notes.get_note(user, vault, "Bootstrap/New.md")
      assert again.id == note.id
    end

    test "returns the existing note without recreating it", %{user: user, vault: vault} do
      {:ok, existing} =
        Notes.upsert_note(user, vault, %{"path" => "Bootstrap/Existing.md", "content" => "# hi"})

      assert {:ok, note} = Notes.get_or_bootstrap_note(user, vault, "Bootstrap/Existing.md")
      assert note.id == existing.id
      assert note.content == "# hi"
    end
  end

  # ---------------------------------------------------------------------------
  # get_note_by_id/3
  # ---------------------------------------------------------------------------

  describe "get_note_by_id/3" do
    test "returns the note for the owner", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "a.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      assert {:ok, fetched} = Notes.get_note_by_id(user, vault, note.id)
      assert fetched.id == note.id
      assert fetched.path == "a.md"
      assert fetched.content == "# A"
    end

    test "returns :not_found for non-existent id", %{user: user, vault: vault} do
      assert {:error, :not_found} = Notes.get_note_by_id(user, vault, Ecto.UUID.generate())
    end

    test "returns :not_found across tenants (RLS)", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "a.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      assert {:error, :not_found} = Notes.get_note_by_id(other_user, other_vault, note.id)
    end
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
  # delete_note_by_id/3
  # ---------------------------------------------------------------------------

  describe "delete_note_by_id/3" do
    test "deletes the note and is not found afterward", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "a.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      assert :ok = Notes.delete_note_by_id(user, vault, note.id)
      assert {:error, :not_found} = Notes.get_note_by_id(user, vault, note.id)
    end

    test "returns :not_found for non-existent id", %{user: user, vault: vault} do
      assert {:error, :not_found} = Notes.delete_note_by_id(user, vault, Ecto.UUID.generate())
    end

    test "RLS: cannot delete another user's note", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "a.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      assert {:error, :not_found} = Notes.delete_note_by_id(other_user, other_vault, note.id)
      # Original still accessible to owner
      assert {:ok, _} = Notes.get_note_by_id(user, vault, note.id)
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

    test "omits folder marker rows (kind != 'note')", %{user: user, vault: vault} do
      # Markers carry only folder ciphertext — no path/content/title — so they
      # cannot be decrypted as notes. Spec invariant: channels broadcast notes
      # only; markers propagate via folder-listing endpoints, not change polls.
      {:ok, _marker} = Notes.create_folder_marker(user, vault, "EmptyFolder")

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Real.md",
          "content" => "# real",
          "mtime" => 1_000.0
        })

      past = DateTime.add(note.updated_at, -60, :second)
      {:ok, changes} = Notes.list_changes(user, vault, past)

      paths = Enum.map(changes, & &1.path)
      assert paths == ["Real.md"]
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

    test "fields: :meta returns full metadata with content omitted", %{user: user, vault: vault} do
      # The sync channel's pull_changes drops content from its reply, so it
      # asks for the metadata-only projection — content_ciphertext (the big
      # column) is never fetched or decrypted.
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Meta/Sparse.md",
          "content" => "# Big body that must not be decrypted",
          "mtime" => 1_000.0
        })

      past = DateTime.add(note.updated_at, -60, :second)
      {:ok, changes} = Notes.list_changes(user, vault, past, fields: :meta)

      change = Enum.find(changes, &(&1.path == "Meta/Sparse.md"))
      assert change != nil
      assert change.title == "Big body that must not be decrypted"
      assert change.folder == "Meta"
      assert change.version == note.version
      assert change.deleted == false
      assert change.content == nil
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

    test "returns {:error, :conflict} when target path exists", %{user: user, vault: vault} do
      {:ok, _a} =
        Notes.upsert_note(user, vault, %{
          "path" => "a.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      {:ok, _b} =
        Notes.upsert_note(user, vault, %{
          "path" => "b.md",
          "content" => "# B",
          "mtime" => 1_000.0
        })

      assert {:error, :conflict} = Notes.rename_note(user, vault, "a.md", "b.md")

      # Original still present, untouched
      assert {:ok, %{path: "a.md"}} = Notes.get_note(user, vault, "a.md")
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

  describe "list_folders_with_counts/2 with markers" do
    test "marker for an otherwise-empty folder appears with count 0",
         %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "Empty")

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      empty = Enum.find(folders, &(&1.folder == "Empty"))
      assert empty
      assert empty.count == 0
    end

    test "marker + real notes dedupe by folder_hmac, count reflects notes",
         %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "Mixed")

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Mixed/a.md",
          "content" => "a",
          "mtime" => 1.0
        })

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Mixed/b.md",
          "content" => "b",
          "mtime" => 1.0
        })

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      mixed = Enum.filter(folders, &(&1.folder == "Mixed"))
      assert length(mixed) == 1
      assert hd(mixed).count == 2
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

    test "does not fetch or decrypt note content (metadata listing)", %{
      user: user,
      vault: vault
    } do
      # Every caller (folders controller note_summary, MCP list_folder, tree
      # loaders) serializes metadata only — content stays projected out so
      # folder browsing never pays content I/O + decrypt.
      Notes.upsert_note(user, vault, %{
        "path" => "Health/Sparse.md",
        "content" => "# never needed here",
        "mtime" => 1_000.0
      })

      {:ok, [note]} = Notes.list_notes_in_folder(user, vault, "Health")
      assert note.title == "never needed here"
      assert note.path == "Health/Sparse.md"
      assert note.content == nil
      assert note.content_ciphertext == nil
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

    test "returns {:error, :conflict} when target folder has notes",
         %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "src/a.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "dst/b.md",
          "content" => "# B",
          "mtime" => 1_000.0
        })

      assert {:error, :conflict} = Notes.rename_folder(user, vault, "src", "dst")

      # Source unchanged
      assert {:ok, %{path: "src/a.md"}} = Notes.get_note(user, vault, "src/a.md")
      assert {:ok, %{path: "dst/b.md"}} = Notes.get_note(user, vault, "dst/b.md")
    end

    test "returns {:error, :conflict} when target folder marker exists",
         %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "src/a.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      {:ok, _} = Notes.create_folder_marker(user, vault, "dst")

      assert {:error, :conflict} = Notes.rename_folder(user, vault, "src", "dst")
    end

    # Lock-down test: documents the nested-collision gap in
    # folder_target_exists?/3. The immediate-children fingerprint check
    # passes (no row sits directly in `dst`), but the cascade then trips
    # the unique (user, vault, path_hmac) constraint when src/sub/x.md
    # tries to become dst/sub/x.md (which already exists). If a future
    # change silently masks this — e.g. by catching the Postgrex error
    # and returning {:ok, _} or {:error, :conflict} without a deliberate
    # design — this test fails and forces a re-review of the gap doc.
    test "nested collision still raises Postgrex.Error (documented gap)",
         %{user: user, vault: vault} do
      # src has a nested file
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "src/sub/x.md",
          "content" => "# X (src)",
          "mtime" => 1_000.0
        })

      # dst is EMPTY at the immediate level (no dst/* row), so
      # folder_target_exists?/3 returns false and the rename proceeds...
      # but dst/sub/x.md already exists, so the cascade collides.
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "dst/sub/x.md",
          "content" => "# X (dst)",
          "mtime" => 1_000.0
        })

      assert_raise Postgrex.Error, fn ->
        Notes.rename_folder(user, vault, "src", "dst")
      end
    end

    test "cascades to all children including nested subfolders",
         %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "src/a.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "src/sub/b.md",
          "content" => "# B",
          "mtime" => 1_000.0
        })

      assert {:ok, 2} = Notes.rename_folder(user, vault, "src", "dst")
      assert {:ok, %{path: "dst/a.md"}} = Notes.get_note(user, vault, "dst/a.md")
      assert {:ok, %{path: "dst/sub/b.md"}} = Notes.get_note(user, vault, "dst/sub/b.md")
      assert {:error, :not_found} = Notes.get_note(user, vault, "src/a.md")
      assert {:error, :not_found} = Notes.get_note(user, vault, "src/sub/b.md")
    end

    test "same-folder rename is a no-op (returns {:ok, _})",
         %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "same/a.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      assert {:ok, _} = Notes.rename_folder(user, vault, "same", "same")
      assert {:ok, %{path: "same/a.md"}} = Notes.get_note(user, vault, "same/a.md")
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

  describe "rename_folder/4 with markers" do
    test "renames a folder marker alongside real notes", %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "Old")

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Old/a.md",
          "content" => "a",
          "mtime" => 1.0
        })

      {:ok, _count} = Notes.rename_folder(user, vault, "Old", "New")

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      names = Enum.map(folders, & &1.folder)
      assert "New" in names
      refute "Old" in names
    end

    test "renames a marker-only folder", %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "LonelyOld")

      {:ok, _count} = Notes.rename_folder(user, vault, "LonelyOld", "LonelyNew")

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      names = Enum.map(folders, & &1.folder)
      assert "LonelyNew" in names
      refute "LonelyOld" in names
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

  describe "list_notes_in_folder/3 with markers" do
    test "excludes folder marker rows from the result", %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "Mixed")

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Mixed/a.md",
          "content" => "a",
          "mtime" => 1.0
        })

      {:ok, notes} = Notes.list_notes_in_folder(user, vault, "Mixed")
      assert length(notes) == 1
      assert hd(notes).path == "Mixed/a.md"
    end
  end

  describe "list_folder_notes_by_id/3" do
    test "returns notes whose folder matches the marker's folder", %{user: user, vault: vault} do
      {:ok, marker} = Notes.create_folder_marker(user, vault, "Projects")

      {:ok, _n1} =
        Notes.upsert_note(user, vault, %{
          "path" => "Projects/a.md",
          "content" => "a",
          "mtime" => 1.0
        })

      {:ok, _n2} =
        Notes.upsert_note(user, vault, %{
          "path" => "Projects/b.md",
          "content" => "b",
          "mtime" => 2.0
        })

      {:ok, _other} =
        Notes.upsert_note(user, vault, %{
          "path" => "Archive/c.md",
          "content" => "c",
          "mtime" => 3.0
        })

      {:ok, notes} = Notes.list_folder_notes_by_id(user, vault, marker.id)
      paths = Enum.map(notes, & &1.path) |> Enum.sort()
      assert paths == ["Projects/a.md", "Projects/b.md"]
    end

    test "returns {:error, :not_found} when marker doesn't exist",
         %{user: user, vault: vault} do
      assert {:error, :not_found} =
               Notes.list_folder_notes_by_id(user, vault, Ecto.UUID.generate())
    end

    test "returns {:error, :not_found} when marker belongs to another vault (RLS)", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      {:ok, marker} = Notes.create_folder_marker(user, vault, "Projects")

      assert {:error, :not_found} =
               Notes.list_folder_notes_by_id(other_user, other_vault, marker.id)
    end

    test "excludes folder markers themselves", %{user: user, vault: vault} do
      {:ok, marker} = Notes.create_folder_marker(user, vault, "Projects")
      {:ok, _child_marker} = Notes.create_folder_marker(user, vault, "Projects/Sub")

      {:ok, _note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Projects/a.md",
          "content" => "a",
          "mtime" => 1.0
        })

      {:ok, notes} = Notes.list_folder_notes_by_id(user, vault, marker.id)
      assert Enum.map(notes, & &1.path) == ["Projects/a.md"]
    end
  end

  # ---------------------------------------------------------------------------
  # delete_folder/3 (cascading)
  # ---------------------------------------------------------------------------

  describe "delete_folder/3" do
    test "soft-deletes an empty folder marker", %{user: user, vault: vault} do
      {:ok, _marker} = Notes.create_folder_marker(user, vault, "Empty")

      assert {:ok, %{deleted: 1}} = Notes.delete_folder(user, vault, "Empty")

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      refute "Empty" in Enum.map(folders, & &1.folder)
    end

    test "cascades through folder marker and direct child notes", %{user: user, vault: vault} do
      {:ok, _marker} = Notes.create_folder_marker(user, vault, "Doomed")

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Doomed/a.md",
          "content" => "a",
          "mtime" => 1.0
        })

      assert {:ok, %{deleted: 2}} = Notes.delete_folder(user, vault, "Doomed")

      assert {:error, :not_found} = Notes.get_note(user, vault, "Doomed/a.md")

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      refute "Doomed" in Enum.map(folders, & &1.folder)
    end

    test "cascades through nested subfolders (marker + sub-marker + nested note)",
         %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "a")
      {:ok, _} = Notes.create_folder_marker(user, vault, "a/b")

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "a/b/c.md",
          "content" => "c",
          "mtime" => 1.0
        })

      assert {:ok, %{deleted: 3}} = Notes.delete_folder(user, vault, "a")

      assert {:error, :not_found} = Notes.get_note(user, vault, "a/b/c.md")

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      names = Enum.map(folders, & &1.folder)
      refute "a" in names
      refute "a/b" in names
    end

    test "does not delete sibling-prefix folders (no false-positive matches)",
         %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "Proj")
      {:ok, _} = Notes.create_folder_marker(user, vault, "Projects")

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Projects/keep.md",
          "content" => "keep",
          "mtime" => 1.0
        })

      assert {:ok, %{deleted: 1}} = Notes.delete_folder(user, vault, "Proj")

      # Projects/keep.md must still be readable.
      assert {:ok, %{path: "Projects/keep.md"}} =
               Notes.get_note(user, vault, "Projects/keep.md")
    end

    test "idempotent: re-deleting an already-deleted folder returns {:ok, %{deleted: 0}}",
         %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "Once")
      {:ok, %{deleted: 1}} = Notes.delete_folder(user, vault, "Once")

      assert {:ok, %{deleted: 0}} = Notes.delete_folder(user, vault, "Once")
    end

    test "returns {:ok, %{deleted: 0}} for nonexistent folder", %{user: user, vault: vault} do
      assert {:ok, %{deleted: 0}} = Notes.delete_folder(user, vault, "Nope")
    end

    test "does not affect other user's folder with the same name", %{
      user: user,
      vault: vault,
      other_user: other_user,
      other_vault: other_vault
    } do
      {:ok, _} =
        Notes.upsert_note(other_user, other_vault, %{
          "path" => "Shared/keep.md",
          "content" => "keep",
          "mtime" => 1.0
        })

      assert {:ok, %{deleted: 0}} = Notes.delete_folder(user, vault, "Shared")

      assert {:ok, _} = Notes.get_note(other_user, other_vault, "Shared/keep.md")
    end

    test "broadcasts per-note delete event for each descendant note", %{
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, _} = Notes.create_folder_marker(user, vault, "Watched")

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Watched/a.md",
          "content" => "a",
          "mtime" => 1.0
        })

      # Drain the upsert broadcast emitted by upsert_note/3.
      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed"}

      assert {:ok, %{deleted: 2}} = Notes.delete_folder(user, vault, "Watched")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: %{"event_type" => "delete", "path" => "Watched/a.md"}
      }
    end
  end

  # ---------------------------------------------------------------------------
  # #746 — rename must repath Qdrant points, not re-embed through Voyage
  # ---------------------------------------------------------------------------

  describe "rename does not re-embed (#746)" do
    test "single-note rename enqueues RepathNoteIndex, not EmbedNote, and keeps embed_hash",
         %{user: user, vault: vault} do
      note =
        Engram.Fixtures.insert_note!(user, vault, %{path: "A/Note.md", content: "# x\n\nbody"})

      import Ecto.Query

      from(n in Engram.Notes.Note, where: n.id == ^note.id)
      |> Engram.Repo.update_all([set: [embed_hash: note.content_hash]], skip_tenant_check: true)

      assert {:ok, _} = Engram.Notes.rename_note(user, vault, "A/Note.md", "B/Note.md")

      assert_enqueued(worker: Engram.Workers.RepathNoteIndex, args: %{note_id: note.id})
      refute_enqueued(worker: Engram.Workers.EmbedNote)

      reloaded = Engram.Repo.get!(Engram.Notes.Note, note.id, skip_tenant_check: true)
      assert reloaded.embed_hash == note.content_hash
    end

    test "folder rename enqueues RepathNoteIndex for each note, not EmbedNote",
         %{user: user, vault: vault} do
      note =
        Engram.Fixtures.insert_note!(user, vault, %{path: "Old/Note.md", content: "# x\n\nbody"})

      import Ecto.Query

      from(n in Engram.Notes.Note, where: n.id == ^note.id)
      |> Engram.Repo.update_all([set: [embed_hash: note.content_hash]], skip_tenant_check: true)

      assert {:ok, _} = Engram.Notes.rename_folder(user, vault, "Old", "New")

      assert_enqueued(worker: Engram.Workers.RepathNoteIndex, args: %{note_id: note.id})
      refute_enqueued(worker: Engram.Workers.EmbedNote)

      reloaded = Engram.Repo.get!(Engram.Notes.Note, note.id, skip_tenant_check: true)
      assert reloaded.embed_hash == note.content_hash
    end
  end
end
