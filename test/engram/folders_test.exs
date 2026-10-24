defmodule Engram.FoldersTest do
  use Engram.DataCase, async: false

  alias Engram.{Attachments, Folders, Notes}

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)
    Mox.stub(Engram.MockStorage, :delete, fn _key -> :ok end)
    Mox.stub(Engram.MockStorage, :delete_many, fn keys -> {:ok, length(keys)} end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  # Flips the last ciphertext byte of the user's wrapped DEK: the blob still
  # carries its version tag (so the provider is identified) but AES-GCM
  # authentication fails, so `get_dek/1` errors rather than returning :no_dek.
  defp corrupt_user_dek!(user) do
    blob = Engram.Repo.reload!(user).encrypted_dek
    last_index = byte_size(blob) - 1
    <<head::binary-size(last_index), last>> = blob

    Engram.Repo.update_all(
      from(u in Engram.Accounts.User, where: u.id == ^user.id),
      [set: [encrypted_dek: <<head::binary, Bitwise.bxor(last, 0xFF)>>]],
      skip_tenant_check: true
    )

    Engram.Crypto.DekCache.invalidate(user.id)
  end

  # Flips a byte of the attachment's encrypted path so AES-GCM auth fails for
  # THAT ROW only — the user DEK still unwraps fine. This is the case
  # `decrypt_each/3` swallows: a partial rebind, or a row written under a
  # rotated-away dek_version.
  defp corrupt_attachment_metadata!(att_id) do
    row = Engram.Repo.get!(Engram.Attachments.Attachment, att_id, skip_tenant_check: true)
    ct = row.path_ciphertext
    last_index = byte_size(ct) - 1
    <<head::binary-size(last_index), last>> = ct

    Engram.Repo.update_all(
      from(a in Engram.Attachments.Attachment, where: a.id == ^att_id),
      [set: [path_ciphertext: <<head::binary, Bitwise.bxor(last, 0xFF)>>]],
      skip_tenant_check: true
    )
  end

  defp att_paths(user, vault) do
    {:ok, metas} = Attachments.list_attachments(user, vault)
    metas |> Enum.map(& &1.path) |> Enum.sort()
  end

  defp put_att(user, vault, path) do
    {:ok, _} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("x")
      })
  end

  test "rename/4 moves both a note and an attachment under the folder", %{
    user: user,
    vault: vault
  } do
    {:ok, _note} =
      Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"}, actor: "api")

    put_att(user, vault, "Docs/a.png")

    assert {:ok, %{notes: 1, attachments: 1}} = Folders.rename(user, vault, "Docs", "Archive")
    assert att_paths(user, vault) == ["Archive/a.png"]
  end

  # Notes and attachments each re-sanitize the target; a single-decode
  # sanitizer let them disagree and split one folder across two paths.
  describe "rename/4 with a double-encoded target" do
    setup %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"}, actor: "api")

      put_att(user, vault, "Docs/a.png")
      %{user: user}
    end

    test "%252e%252e is refused, nothing moves", %{user: user, vault: vault} do
      assert {:error, :invalid_path} = Folders.rename(user, vault, "Docs", "%252e%252e")
      assert att_paths(user, vault) == ["Docs/a.png"]
      assert {:ok, _} = Notes.get_note(user, vault, "Docs/n.md")
    end

    test "B/%252e%252e keeps notes and attachments together in B", %{user: user, vault: vault} do
      assert {:ok, %{notes: 1, attachments: 1}} =
               Folders.rename(user, vault, "Docs", "B/%252e%252e")

      assert att_paths(user, vault) == ["B/a.png"]
      assert {:ok, _} = Notes.get_note(user, vault, "B/n.md")
    end

    test "a%252Fb keeps notes and attachments together in a/b", %{user: user, vault: vault} do
      assert {:ok, %{notes: 1, attachments: 1}} = Folders.rename(user, vault, "Docs", "a%252Fb")
      assert att_paths(user, vault) == ["a/b/a.png"]
      assert {:ok, _} = Notes.get_note(user, vault, "a/b/n.md")
    end
  end

  test "batch_delete/3 soft-deletes the folder's attachments", %{user: user, vault: vault} do
    {:ok, marker} = Notes.create_folder_marker(user, vault, "Docs")
    put_att(user, vault, "Docs/a.png")

    assert {:ok, %{notes: _, attachments: 1}} = Folders.batch_delete(user, vault, [marker.id])
    assert att_paths(user, vault) == []
  end

  test "batch_move/4 moves the folder's attachments under the target", %{user: user, vault: vault} do
    {:ok, src} = Notes.create_folder_marker(user, vault, "Docs")
    {:ok, _dst} = Notes.create_folder_marker(user, vault, "Archive")
    put_att(user, vault, "Docs/a.png")

    assert {:ok, %{notes: _, attachments: 1}} =
             Folders.batch_move(user, vault, [src.id], {:path, "Archive"})

    assert att_paths(user, vault) == ["Archive/Docs/a.png"]
  end

  describe "single-scan partition across multiple folders (#9)" do
    test "batch_delete/3 soft-deletes attachments under 2+ folders in one scan", %{
      user: user,
      vault: vault
    } do
      {:ok, m1} = Notes.create_folder_marker(user, vault, "Docs")
      {:ok, m2} = Notes.create_folder_marker(user, vault, "Notes")
      put_att(user, vault, "Docs/a.png")
      put_att(user, vault, "Docs/sub/b.png")
      put_att(user, vault, "Notes/c.png")
      put_att(user, vault, "Keep/d.png")

      assert {:ok, %{attachments: 3}} = Folders.batch_delete(user, vault, [m1.id, m2.id])

      # Only the attachment outside both deleted folders survives.
      assert att_paths(user, vault) == ["Keep/d.png"]
    end

    test "batch_move/4 relocates attachments under 2+ folders in one scan", %{
      user: user,
      vault: vault
    } do
      {:ok, s1} = Notes.create_folder_marker(user, vault, "Docs")
      {:ok, s2} = Notes.create_folder_marker(user, vault, "Notes")
      {:ok, _dst} = Notes.create_folder_marker(user, vault, "Archive")
      put_att(user, vault, "Docs/a.png")
      put_att(user, vault, "Notes/sub/b.png")
      put_att(user, vault, "Keep/c.png")

      assert {:ok, %{attachments: 2}} =
               Folders.batch_move(user, vault, [s1.id, s2.id], {:path, "Archive"})

      assert att_paths(user, vault) == [
               "Archive/Docs/a.png",
               "Archive/Notes/sub/b.png",
               "Keep/c.png"
             ]
    end
  end

  describe "nested-folder batch-move resolves attachments by longest-prefix (Fix #2)" do
    # Scope: this proves the ATTACHMENT resolution (`rename_target`) is
    # deterministic — given a pair set where an attachment matches BOTH a parent
    # and a nested-child prefix, the most-specific (longest) prefix wins,
    # regardless of pair ORDER. Full parent+child consistency with the NOTES
    # leg's own sequential overlapping-selection cascade (which can rewrite the
    # pair set mid-move) is a separate pre-existing concern, out of scope here.

    test "an attachment under a nested child follows the most-specific mapping", %{
      user: user,
      vault: vault
    } do
      # Use distinct targets so the notes leg does NOT rewrite one pair into the
      # other (no shared destination prefix) — the attachment partition then
      # sees two genuinely overlapping source prefixes (Docs and Docs/Sub) and
      # must pick the deepest (Docs/Sub → Nested).
      {:ok, parent} = Notes.create_folder_marker(user, vault, "Docs")
      {:ok, child} = Notes.create_folder_marker(user, vault, "Docs/Sub")
      {:ok, _t1} = Notes.create_folder_marker(user, vault, "ParentDest")
      {:ok, _t2} = Notes.create_folder_marker(user, vault, "ChildDest")
      put_att(user, vault, "Docs/Sub/a.png")

      # Move child → ChildDest, parent → ParentDest, in ONE batch.
      assert {:ok, %{attachments: 1}} =
               Folders.batch_move(user, vault, [child.id, parent.id], {:path, "ChildDest"})

      # The child marker moved to ChildDest/Sub; the attachment under Docs/Sub
      # must follow the most-specific Docs/Sub mapping → ChildDest/Sub/a.png,
      # NOT ParentDest/... or a parent-derived path.
      assert att_paths(user, vault) == ["ChildDest/Sub/a.png"]
    end

    test "the resolver picks the longest matching prefix regardless of pair order" do
      # Directly exercise the resolution over a controlled overlapping pair set
      # in BOTH orders, proving determinism independent of the notes leg.
      path = "Docs/Sub/a.png"
      parent = {"Docs", "Archive/Docs"}
      child = {"Docs/Sub", "Archive/Sub"}

      assert Folders.resolve_attachment_target(path, [parent, child]) ==
               {:ok, "Archive/Sub/a.png"}

      assert Folders.resolve_attachment_target(path, [child, parent]) ==
               {:ok, "Archive/Sub/a.png"}

      assert Folders.resolve_attachment_target("Other/x.png", [parent, child]) == :no_match
    end
  end

  defp note_path(user, vault, id) do
    {:ok, note} = Notes.get_note_by_id(user, vault, id)
    note.path
  end

  describe "atomicity across the notes + attachments legs" do
    test "rename/4 rolls BOTH legs back when the attachment leg conflicts", %{
      user: user,
      vault: vault
    } do
      # Notes leg moves cleanly (Docs/n.md -> Archive/n.md), but the attachment
      # leg conflicts: Archive/a.png is already occupied. Pre-Bug-3 the notes
      # commit stuck while attachments didn't → permanent split state. The fix
      # makes the coordinator atomic: a conflict rolls the note move back too.
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"}, actor: "api")

      put_att(user, vault, "Docs/a.png")
      put_att(user, vault, "Archive/a.png")

      assert {:error, :conflict} = Folders.rename(user, vault, "Docs", "Archive")

      # The note must NOT have moved — both tables roll back together.
      assert note_path(user, vault, note.id) == "Docs/n.md"
      # Source attachment untouched too.
      assert "Docs/a.png" in att_paths(user, vault)
    end

    test "batch_move/4 rolls BOTH legs back when the attachment leg conflicts", %{
      user: user,
      vault: vault
    } do
      # Notes leg moves the marker cleanly, attachment leg conflicts on a
      # pre-occupied destination. Atomic coordinator must roll the note move back.
      {:ok, src} = Notes.create_folder_marker(user, vault, "Docs")
      {:ok, _dst} = Notes.create_folder_marker(user, vault, "Archive")

      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"}, actor: "api")

      put_att(user, vault, "Docs/a.png")
      # Pre-occupy the attachment move destination (Archive/Docs/a.png).
      put_att(user, vault, "Archive/Docs/a.png")

      assert {:error, :conflict} =
               Folders.batch_move(user, vault, [src.id], {:path, "Archive"})

      # Note move rolled back.
      assert note_path(user, vault, note.id) == "Docs/n.md"
    end
  end

  # #2159: a 7,440-attachment folder delete ran as ONE transaction, held the
  # vault seq lock through it, and hit the 15 s checkout kill. A cascade is now
  # a run of short transactions (attachments, then notes, then markers), so a
  # failure keeps what committed and a retry finishes the rest.
  describe "chunked delete cascade (#2159)" do
    setup do
      prev = Application.get_env(:engram, :folder_delete_chunk)
      Application.put_env(:engram, :folder_delete_chunk, 1)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:engram, :folder_delete_chunk, prev),
          else: Application.delete_env(:engram, :folder_delete_chunk)
      end)

      :ok
    end

    defp att_id(user, vault, path) do
      {:ok, metas} = Attachments.list_attachments(user, vault)
      Enum.find(metas, &(&1.path == path)).id
    end

    # A DB error on the soft delete of one attachment row, mid-cascade.
    defp fail_deleting!(att_id) do
      Engram.Repo.query!("""
      CREATE FUNCTION test_fail_2159() RETURNS trigger AS $$
      BEGIN
        IF NEW.id = '#{att_id}'::uuid AND NEW.deleted_at IS NOT NULL THEN
          RAISE EXCEPTION 'injected failure';
        END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """)

      Engram.Repo.query!(
        "CREATE TRIGGER test_fail_2159 BEFORE UPDATE ON attachments " <>
          "FOR EACH ROW EXECUTE FUNCTION test_fail_2159()"
      )
    end

    defp stop_failing!, do: Engram.Repo.query!("DROP TRIGGER test_fail_2159 ON attachments")

    defp seed(user, vault) do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"}, actor: "api")

      for p <- ["Docs/a.png", "Docs/b.png", "Docs/c.png"], do: put_att(user, vault, p)
      note
    end

    test "delete/4: a failure keeps earlier chunks, the folder stays, a retry finishes", %{
      user: user,
      vault: vault
    } do
      note = seed(user, vault)
      fail_deleting!(att_id(user, vault, "Docs/b.png"))

      assert_raise Postgrex.Error, ~r/injected failure/, fn ->
        Folders.delete(user, vault, "Docs", recursive: true)
      end

      # Chunk 1 (a) committed; b failed; c and the note never ran.
      assert att_paths(user, vault) == ["Docs/b.png", "Docs/c.png"]
      assert note_path(user, vault, note.id) == "Docs/n.md"

      stop_failing!()

      assert {:ok, %{notes: 1, attachments: 2}} =
               Folders.delete(user, vault, "Docs", recursive: true)

      assert att_paths(user, vault) == []
      assert {:error, :not_found} = Notes.get_note(user, vault, "Docs/n.md")
    end

    test "batch_delete/3: the marker goes last, so a retry by id still finds it", %{
      user: user,
      vault: vault
    } do
      {:ok, marker} = Notes.create_folder_marker(user, vault, "Docs")
      seed(user, vault)
      fail_deleting!(att_id(user, vault, "Docs/b.png"))

      assert_raise Postgrex.Error, ~r/injected failure/, fn ->
        Folders.batch_delete(user, vault, [marker.id])
      end

      stop_failing!()

      assert {:ok, %{attachments: 2}} = Folders.batch_delete(user, vault, [marker.id])
      assert att_paths(user, vault) == []
    end

    test "each chunk is its own transaction; none holds the seq lock across chunks", %{
      user: user,
      vault: vault
    } do
      seed(user, vault)

      {{:ok, %{notes: 1, attachments: 3}}, queries} =
        Engram.QueryRecorder.record(fn -> Folders.delete(user, vault, "Docs", recursive: true) end)

      txns = Engram.QueryRecorder.transactions(queries)
      seq_bumps = fn txn -> Enum.count(txn, &(&1 =~ "change_seq = change_seq +")) end

      writes = fn txn, table ->
        Enum.any?(txn, &(&1 =~ ~r/^(UPDATE|DELETE FROM) "?#{table}\b/))
      end

      assert Enum.count(txns, &(seq_bumps.(&1) > 0)) >= 4,
             "3 attachment chunks + 1 note chunk, each with its own seq\n" <>
               Engram.QueryRecorder.format(queries)

      for txn <- txns do
        assert seq_bumps.(txn) <= 1, Engram.QueryRecorder.format(queries)
        refute writes.(txn, "notes") and writes.(txn, "attachments")
      end
    end

    test "a derived folder (notes only, no marker) deletes fully, every delete in the feed", %{
      user: user,
      vault: vault
    } do
      notes =
        for p <- ["Derived/a.md", "Derived/Sub/b.md"] do
          {:ok, n} =
            Notes.upsert_note(user, vault, %{"path" => p, "content" => "x"}, actor: "api")

          n
        end

      before = Engram.Vaults.current_seq(user.id, vault.id)

      assert {:ok, %{notes: 2}} = Folders.delete(user, vault, "Derived", recursive: true)

      for n <- notes do
        row = Engram.Repo.get!(Engram.Notes.Note, n.id, skip_tenant_check: true)
        assert row.deleted_at
        assert row.seq > before
      end
    end
  end

  # #2159: MCP rename_folder on the same 7,440-attachment vault hit the 15 s
  # checkout kill 4 times: one repoint + tombstone + job per attachment, all
  # in one transaction, with the decrypt-scan inside it too.
  describe "folder rename batches the attachment leg (#2159)" do
    test "statement count in the rename transaction does not grow with attachments", %{
      user: user,
      vault: vault
    } do
      for i <- 1..30, do: put_att(user, vault, "Docs/f#{i}.png")

      {{:ok, %{attachments: 30}}, queries} =
        Engram.QueryRecorder.record(fn -> Folders.rename(user, vault, "Docs", "Archive") end)

      largest =
        queries |> Engram.QueryRecorder.transactions() |> Enum.map(&length/1) |> Enum.max()

      assert largest < 30,
             "the rename transaction ran #{largest} statements for 30 attachments\n" <>
               Engram.QueryRecorder.format(queries)

      assert att_paths(user, vault) == Enum.sort(for i <- 1..30, do: "Archive/f#{i}.png")
    end

    # ~7,500 attachments scaled down: 75 rows in chunks of 10 is the same
    # shape (8 chunks) as 7,500 in chunks of 500 (15). The attachment leg is
    # a fixed handful of statements per chunk, so the transaction stays
    # O(chunks) however many attachments the folder holds.
    test "a large rename's transaction is O(chunks), not O(attachments)", %{
      user: user,
      vault: vault
    } do
      prev = Application.get_env(:engram, :attachments_bulk_chunk)
      Application.put_env(:engram, :attachments_bulk_chunk, 10)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:engram, :attachments_bulk_chunk, prev),
          else: Application.delete_env(:engram, :attachments_bulk_chunk)
      end)

      for i <- 1..75, do: put_att(user, vault, "Big/f#{i}.png")

      {{:ok, %{attachments: 75}}, queries} =
        Engram.QueryRecorder.record(fn -> Folders.rename(user, vault, "Big", "Moved") end)

      txn = queries |> Engram.QueryRecorder.transactions() |> Enum.max_by(&length/1)
      on_attachments = Enum.count(txn, &(&1 =~ ~r/^(UPDATE|INSERT INTO) "?attachments\b/))

      # 8 repoint UPDATEs + 8 tombstone INSERTs; per-item would be 150.
      assert on_attachments == 16, Engram.QueryRecorder.format(queries)
      assert length(txn) < 75, Engram.QueryRecorder.format(queries)
    end

    test "a source deleted after the scan is skipped and reported, not a failed rename", %{
      user: user,
      vault: vault
    } do
      put_att(user, vault, "Docs/a.png")
      put_att(user, vault, "Docs/b.png")
      {:ok, pairs} = Attachments.folder_rename_pairs(user, vault, "Docs", "Archive")

      # A syncing client deletes b between the scan and the rename transaction.
      :ok = Attachments.delete_attachment(user, vault, "Docs/b.png")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 1} = Attachments.move_folder_pairs(user, vault, pairs)
        end)

      assert log =~ "attachments skipped, deleted or moved after the scan"
      assert log =~ "total_count=1"
      assert att_paths(user, vault) == ["Archive/a.png"]
    end

    # A delete committing between the source read and the UPDATE would make
    # the UPDATE match one row fewer and raise; the lock makes it wait.
    test "the source read locks the rows it will move", %{user: user, vault: vault} do
      put_att(user, vault, "Docs/a.png")

      {{:ok, %{attachments: 1}}, queries} =
        Engram.QueryRecorder.record(fn -> Folders.rename(user, vault, "Docs", "Archive") end)

      assert Enum.any?(queries, &(&1.sql =~ ~r/FROM "attachments".*FOR UPDATE/s)),
             Engram.QueryRecorder.format(queries)
    end

    test "a user's explicit batch_move still refuses a missing source", %{
      user: user,
      vault: vault
    } do
      put_att(user, vault, "Docs/a.png")

      assert {:error, {:not_found, "Docs/gone.png"}} =
               Attachments.batch_move(user, vault, ["Docs/a.png", "Docs/gone.png"], "Archive")

      assert att_paths(user, vault) == ["Docs/a.png"]
    end

    # #614: a repoint and its tombstone share ONE seq, so a cursor pull never
    # sees one without the other; distinct items keep distinct seqs.
    test "every moved attachment leaves an old-path tombstone at its own seq", %{
      user: user,
      vault: vault
    } do
      put_att(user, vault, "Docs/a.png")
      put_att(user, vault, "Docs/Sub/b.png")

      assert {:ok, %{attachments: 2}} = Folders.rename(user, vault, "Docs", "Archive")

      rows =
        Engram.Repo.all(
          from(a in Engram.Attachments.Attachment, where: a.vault_id == ^vault.id),
          skip_tenant_check: true
        )

      {live, tombs} = Enum.split_with(rows, &is_nil(&1.deleted_at))
      assert length(live) == 2 and length(tombs) == 2
      assert Enum.all?(tombs, &is_nil(&1.storage_key))
      assert rows |> Enum.frequencies_by(& &1.seq) |> Map.values() == [2, 2]
    end
  end

  describe "cascade broadcasts defer until the outer transaction commits (Fix #1)" do
    test "rename/4 emits NO note_changed events when the attachment leg rolls back", %{
      user: user,
      vault: vault
    } do
      # Same rollback scenario as the atomicity test: notes leg moves cleanly but
      # the attachment destination is occupied → outer transaction rolls back.
      # Pre-fix, the notes-leg per-note delete/upsert broadcasts fired as the
      # inner txn released (BEFORE the outer rollback) → phantom events.
      {:ok, _note} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"}, actor: "api")

      put_att(user, vault, "Docs/a.png")
      put_att(user, vault, "Archive/a.png")

      topic = "sync:#{user.id}:#{vault.id}"
      EngramWeb.Endpoint.subscribe(topic)

      assert {:error, :conflict} = Folders.rename(user, vault, "Docs", "Archive")

      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "note_changed"}, 100
    end

    test "rename/4 DOES emit note_changed events when the cascade commits", %{
      user: user,
      vault: vault
    } do
      {:ok, _note} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"}, actor: "api")

      put_att(user, vault, "Docs/a.png")

      topic = "sync:#{user.id}:#{vault.id}"
      EngramWeb.Endpoint.subscribe(topic)

      assert {:ok, %{notes: 1, attachments: 1}} = Folders.rename(user, vault, "Docs", "Archive")

      # Deferred buffer flushed post-commit: the cascade's events arrive.
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "note_changed"}, 200
    end

    test "standalone move_attachment broadcasts immediately (single-item path unchanged)", %{
      user: user,
      vault: vault
    } do
      put_att(user, vault, "a.png")

      topic = "sync:#{user.id}:#{vault.id}"
      EngramWeb.Endpoint.subscribe(topic)

      assert {:ok, _} = Attachments.move_attachment(user, vault, "a.png", "moved.png")

      # No deferral active → broadcast fires immediately, exactly as before.
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "note_changed"}, 200
    end
  end

  test "batch_delete/3 with empty ids returns zero counts", %{user: user, vault: vault} do
    assert {:ok, %{notes: 0, attachments: 0}} = Folders.batch_delete(user, vault, [])
  end

  test "batch_move/4 with empty ids returns zero counts", %{user: user, vault: vault} do
    assert {:ok, %{notes: 0, attachments: 0}} =
             Folders.batch_move(user, vault, [], {:path, "Archive"})
  end

  describe "delete/4" do
    test "deletes an empty folder marker (no recursive flag)", %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "Empty")

      assert {:ok, %{notes: 0, attachments: 0}} = Folders.delete(user, vault, "Empty")

      {:ok, folders} = Notes.list_folders_with_counts(user, vault)
      refute Enum.any?(folders, &(&1.folder == "Empty"))
    end

    test "refuses a non-empty folder without recursive and reports counts", %{
      user: user,
      vault: vault
    } do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Docs/p.png",
          "content_base64" => Base.encode64("x")
        })

      assert {:error, {:not_empty, %{notes: 1, attachments: 1}}} =
               Folders.delete(user, vault, "Docs")

      assert {:ok, _} = Notes.get_note(user, vault, "Docs/a.md")
    end

    test "reports a fault instead of reading an unreadable vault as empty", %{
      user: user,
      vault: vault
    } do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      # The emptiness guard is the only thing standing between a non-recursive
      # delete and a full folder, and it is built from two counters that both
      # need the DEK. Corrupt the wrapped DEK so it still IDENTIFIES as a v2
      # blob but fails to unwrap — the shape a KMS outage or a rotated-away
      # master key takes. "I couldn't tell" must not render as 0.
      corrupt_user_dek!(user)
      broken = Engram.Accounts.get_user!(user.id)

      assert {:error, reason} = Folders.delete(broken, vault, "Docs")
      refute match?({:not_empty, _}, reason)

      # Nothing was deleted: the note is readable again once the DEK is.
      # (`get_dek/1` unwraps the blob the DB holds, not the caller's struct,
      # so the DEK has to actually be repaired.)
      Engram.Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [encrypted_dek: user.encrypted_dek]],
        skip_tenant_check: true
      )

      Engram.Crypto.DekCache.invalidate(user.id)
      assert {:ok, _} = Notes.get_note(user, vault, "Docs/a.md")
    end

    # `Crypto.get_dek/1` reads `encrypted_dek` off the STRUCT, so a caller
    # holding a pre-provisioning copy got `:no_dek` -> count 0 -> "empty" —
    # while `Notes.delete_folder/3`'s own `ensure_user_dek/1` reloads under FOR
    # UPDATE, finds the real blob, and cascades happily. That combination
    # deletes a full folder and reports it as empty.
    test "a stale user struct cannot make a full folder look empty", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      stale = %{user | encrypted_dek: nil}

      assert {:error, {:not_empty, %{notes: 1}}} = Folders.delete(stale, vault, "Docs")
      assert {:ok, _} = Notes.get_note(user, vault, "Docs/a.md")
    end

    # The tolerant listing drops undecryptable rows, so a folder holding only
    # unreadable attachments counted as empty and was cascaded — leaving live
    # rows orphaned under a path the user was told had been deleted.
    test "an undecryptable attachment is not counted as an empty folder", %{
      user: user,
      vault: vault
    } do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Docs/p.png",
          "content_base64" => Base.encode64("x")
        })

      corrupt_attachment_metadata!(att.id)

      assert {:error, {:unverifiable, %{undecryptable_attachments: 1}}} =
               Folders.delete(user, vault, "Docs")

      # Still on disk — the guard refused rather than cascading over it. The
      # strict listing erroring IS the proof: the row is present and unreadable.
      assert {:error, {:undecryptable_attachments, 1}} =
               Attachments.list_attachments_strict(user, vault)
    end

    # #1334 closed the create-in-the-gap race by scanning once and deleting by
    # id from that scan. This is the opposite race it traded for: under READ
    # COMMITTED each statement takes its own snapshot, so a concurrent same-user
    # transaction can move a note OUT of the folder after `scan_folders/3`
    # captured its id and before `delete_scanned/3` applies. The id is still in
    # the match set, so the note is deleted from a folder the user never asked
    # to touch.
    #
    # Driving scan and delete as separate calls with a move between them is the
    # race made deterministic — it is the exact interleaving, minus the
    # scheduling luck needed to hit it with real concurrency.
    test "a note moved out between scan and delete is NOT deleted", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/b.md", "content" => "y", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, matches} = Notes.scan_folders(user, vault, ["Docs"])
      assert Enum.count(matches, &(&1.kind == "note")) == 2

      # The concurrent transaction commits here.
      {:ok, _} = Notes.rename_note(user, vault, "Docs/a.md", "Archive/a.md")

      {:ok, %{deleted: _}} = Notes.delete_scanned(user, vault, matches)

      # The moved note lives in a folder that was never targeted.
      assert {:ok, _} = Notes.get_note(user, vault, "Archive/a.md")

      # ...and the delete still did its job for what genuinely remained.
      assert {:error, :not_found} = Notes.get_note(user, vault, "Docs/b.md")
    end

    # The count reaching the user has to come from the write, not the scan.
    # A concurrent folder RENAME re-keys folder_hmac on every descendant, so
    # the fence legitimately removes nothing — and reporting the scan's count
    # would tell the user "3 notes removed" when the answer is zero.
    test "reports notes actually deleted, not notes scanned", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, matches} = Notes.scan_folders(user, vault, ["Docs"])
      {:ok, _} = Notes.rename_note(user, vault, "Docs/a.md", "Archive/a.md")

      assert {:ok, %{deleted: 0, notes: 0}} = Notes.delete_scanned(user, vault, matches)
    end

    # The fence firing is the only in-prod evidence the race is real, and it
    # leaves a live note under a folder whose markers were just removed.
    test "logs a warning when the fence skips a row", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, matches} = Notes.scan_folders(user, vault, ["Docs"])
      {:ok, _} = Notes.rename_note(user, vault, "Docs/a.md", "Archive/a.md")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} = Notes.delete_scanned(user, vault, matches)
        end)

      assert log =~ "membership fence skipped rows"
    end

    # A clean delete must stay quiet — a warning on every folder delete would
    # train the operator to ignore the one that matters.
    test "logs nothing when the fence skips nothing", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, matches} = Notes.scan_folders(user, vault, ["Docs"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, %{notes: 1}} = Notes.delete_scanned(user, vault, matches)
        end)

      refute log =~ "membership fence skipped rows"
    end

    # The fence must re-assert membership, not merely count rows: a same-folder
    # write between scan and delete changes seq/updated_at but not folder_hmac,
    # so it must NOT be mistaken for a move and skipped.
    test "a note edited in place between scan and delete is still deleted", %{
      user: user,
      vault: vault
    } do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, matches} = Notes.scan_folders(user, vault, ["Docs"])

      {:ok, _} =
        Notes.upsert_note(
          user,
          vault,
          %{
            "path" => "Docs/a.md",
            "content" => "edited",
            "mtime" => 2.0
          },
          actor: "api"
        )

      {:ok, %{deleted: _}} = Notes.delete_scanned(user, vault, matches)

      assert {:error, :not_found} = Notes.get_note(user, vault, "Docs/a.md")
    end

    # The first attempt at the fix above applied the fail-closed check to the
    # WHOLE vault before filtering by folder, so one corrupt row anywhere made
    # every folder delete in the vault fail — including recursive. Worse than
    # the bug it replaced.
    test "one unreadable attachment elsewhere does not block other deletes", %{
      user: user,
      vault: vault
    } do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Photos/old.png",
          "content_base64" => Base.encode64("x")
        })

      corrupt_attachment_metadata!(att.id)
      {:ok, _} = Notes.create_folder_marker(user, vault, "Drafts")

      # `Drafts` is genuinely empty and the corrupt row is under `Photos`.
      assert {:error, {:unverifiable, _}} = Folders.delete(user, vault, "Drafts")

      # ...and recursive must always have a way through.
      assert {:ok, %{notes: 0}} = Folders.delete(user, vault, "Drafts", recursive: true)
    end

    test "recursive deletes notes + attachments under the folder", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, _} =
        Notes.upsert_note(
          user,
          vault,
          %{
            "path" => "Docs/Sub/b.md",
            "content" => "y",
            "mtime" => 1.0
          },
          actor: "api"
        )

      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Docs/p.png",
          "content_base64" => Base.encode64("x")
        })

      assert {:ok, %{notes: 2, attachments: 1}} =
               Folders.delete(user, vault, "Docs", recursive: true)

      assert {:error, :not_found} = Notes.get_note(user, vault, "Docs/a.md")
      assert {:error, :not_found} = Notes.get_note(user, vault, "Docs/Sub/b.md")
      {:ok, metas} = Attachments.list_attachments(user, vault)
      assert metas == []
    end

    test "deleting a non-existent folder is a no-op success", %{user: user, vault: vault} do
      assert {:ok, %{notes: 0, attachments: 0}} = Folders.delete(user, vault, "Ghost")
    end

    test "trailing slash normalizes to the same non-empty refusal as no-slash (Fix #3)", %{
      user: user,
      vault: vault
    } do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      assert {:error, {:not_empty, %{notes: 1, attachments: 0}}} =
               Folders.delete(user, vault, "Docs/")

      assert {:ok, _} = Notes.get_note(user, vault, "Docs/a.md")
    end

    test "refuses to delete the vault root (Fix #4)", %{user: user, vault: vault} do
      assert {:error, :root_delete_refused} = Folders.delete(user, vault, "")
    end
  end
end
