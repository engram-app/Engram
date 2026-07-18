defmodule Engram.Notes.CrdtTransportTest do
  # async: false — later tasks in this file spawn :global rooms; keep the whole
  # module on the shared-mode sandbox so room-spawning and read tests coexist.
  use Engram.DataCase, async: false

  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, CrdtTransport, CrdtUpdateLog, Note}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "TransportTest"})
    %{user: user, vault: vault}
  end

  # Append a crdt_update_log (tail) row SYNCHRONOUSLY, to advance the tail
  # watermark deterministically in the CAS tests. (A real apply_update settles
  # the tail asynchronously — which is exactly the race the CAS guards, but it
  # makes a watermark assertion non-deterministic.) Returns the new row's id.
  defp append_tail_row(user, vault, note_id) do
    {:ok, row} =
      Repo.with_tenant(user.id, fn ->
        %CrdtUpdateLog{}
        |> CrdtUpdateLog.changeset(%{
          note_id: note_id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: <<0>>,
          update_nonce: <<0>>
        })
        |> Repo.insert!()
      end)

    row.id
  end

  describe "read_delta/4" do
    test "full state (since=nil) reconstructs the note text on a fresh client doc",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/A.md", content: "# A\n\nhello", mtime: 1_000.0})

      assert {:ok, %{update: update, head: head}} =
               CrdtTransport.read_delta(user, vault, note.id, nil)

      assert is_binary(update) and byte_size(update) > 0
      assert is_binary(head) and byte_size(head) > 0

      # Apply the returned full-state update to a brand-new client doc; it must
      # project the same body the server holds — proof the transport round-trips.
      client = CrdtBridge.new_doc()
      assert :ok = Yex.apply_update(client, update)
      assert CrdtBridge.body_of(client) =~ "hello"
    end

    test "delta (since=client SV) carries only the change after the client's state",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/B.md", content: "# B\n\none", mtime: 1_000.0})

      # Client catches up to the current server state, records its SV, THEN the
      # server advances. The delta since that SV must reproduce the new text.
      {:ok, %{update: full}} = CrdtTransport.read_delta(user, vault, note.id, nil)
      client = CrdtBridge.new_doc()
      :ok = Yex.apply_update(client, full)
      client_sv = Yex.encode_state_vector!(client)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          path: "T/B.md",
          content: "# B\n\none two",
          mtime: 2_000.0
        })

      assert {:ok, %{update: delta}} = CrdtTransport.read_delta(user, vault, note.id, client_sv)
      assert :ok = Yex.apply_update(client, delta)
      assert CrdtBridge.body_of(client) =~ "two"
    end

    test "unknown note id → {:error, :not_found}", %{user: user, vault: vault} do
      assert {:error, :not_found} =
               CrdtTransport.read_delta(user, vault, Ecto.UUID.generate(), nil)
    end

    test "valid-base64 but non-state-vector since bytes → {:error, :bad_since}, never raises",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/BadSV.md", content: "# X", mtime: 1_000.0})

      # A short truncated-varint pattern: the NIF itself rejects it with
      # {:error, {:encoding_exception, _}} (confirmed empirically), no crash.
      assert {:error, :bad_since} =
               CrdtTransport.read_delta(user, vault, note.id, :binary.copy(<<0x80>>, 10))
    end

    test "state vector claiming an implausible entry count → {:error, :bad_since}, never crashes",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/BadSV2.md", content: "# Y", mtime: 1_000.0})

      # DELIBERATELY NOT random bytes: <<128, 128, 128, 128, 15>> decodes as a
      # state vector claiming ~2^31 client entries in 5 bytes. Handed directly
      # to Yex.encode_state_as_update/2, this makes the NIF request a ~150 GB
      # allocation; Rust's OOM handler calls abort() (not a catchable panic),
      # which kills the whole BEAM VM process for every user. Confirmed via a
      # throwaway `mix run` script outside the test suite (would otherwise
      # crash the test runner itself). plausible_state_vector?/1 must reject
      # this before it ever reaches the NIF.
      malicious_sv = <<128, 128, 128, 128, 15>>

      assert {:error, :bad_since} =
               CrdtTransport.read_delta(user, vault, note.id, malicious_sv)
    end
  end

  describe "apply_update/4" do
    test "a client update merges losslessly and advances the head", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/C.md", content: "# C\n\nseed", mtime: 1_000.0})

      on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

      # Build a real client update: catch up, edit locally, encode the delta.
      {:ok, %{update: full, head: head0}} = CrdtTransport.read_delta(user, vault, note.id, nil)
      client = CrdtBridge.new_doc()
      :ok = Yex.apply_update(client, full)
      before_sv = Yex.encode_state_vector!(client)
      CrdtBridge.ingest_plaintext(client, "# C\n\nseed and client edit")
      {:ok, client_update} = Yex.encode_state_as_update(client, before_sv)

      assert {:ok, %{head: head1}} =
               CrdtTransport.apply_update(user, vault, note.id, client_update)

      assert head1 != head0

      # The server now serves the client's edit back to a third, empty reader.
      {:ok, %{update: full2}} = CrdtTransport.read_delta(user, vault, note.id, nil)
      reader = CrdtBridge.new_doc()
      :ok = Yex.apply_update(reader, full2)
      assert CrdtBridge.body_of(reader) =~ "client edit"
    end

    test "garbage bytes → {:error, :invalid_update}", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/D.md", content: "# D", mtime: 1_000.0})

      on_exit(fn -> Engram.Notes.CrdtRegistry.terminate_room(note.id) end)

      assert {:error, :invalid_update} =
               CrdtTransport.apply_update(user, vault, note.id, <<255, 254, 253, 0, 1, 2>>)
    end

    test "note in another vault → {:error, :not_found}", %{user: user, vault: vault} do
      assert {:error, :not_found} =
               CrdtTransport.apply_update(user, vault, Ecto.UUID.generate(), <<0, 0>>)
    end

    test "apply_update observes so the room reaps when the caller exits (no immortal-room leak)",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/Leak.md", content: "# Leak", mtime: 1_000.0})

      on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

      {:ok, %{update: full}} = CrdtTransport.read_delta(user, vault, note.id, nil)
      client = CrdtBridge.new_doc()
      :ok = Yex.apply_update(client, full)
      before_sv = Yex.encode_state_vector!(client)
      CrdtBridge.ingest_plaintext(client, "# Leak edit")
      {:ok, upd} = Yex.encode_state_as_update(client, before_sv)

      test_pid = self()

      caller =
        spawn(fn ->
          {:ok, _} = CrdtTransport.apply_update(user, vault, note.id, upd)
          send(test_pid, :applied)
        end)

      caller_ref = Process.monitor(caller)
      assert_receive :applied, 5000

      # The room exists (the apply started/observed it); capture + monitor it.
      room = CrdtRegistry.lookup(note.id)
      assert is_pid(room), "apply_update should have started the room"
      room_ref = Process.monitor(room)

      # Caller process exits → its observer :DOWN → room (sole observer) must reap.
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, _}, 5000
      assert_receive {:DOWN, ^room_ref, :process, ^room, _}, 5000
    end
  end

  describe "vault_heads/2" do
    test "returns a marker per note and only the edited note's marker changes",
         %{user: user, vault: vault} do
      {:ok, a} = Notes.upsert_note(user, vault, %{path: "H/A.md", content: "# A", mtime: 1_000.0})
      {:ok, b} = Notes.upsert_note(user, vault, %{path: "H/B.md", content: "# B", mtime: 1_000.0})

      heads0 = CrdtTransport.vault_heads(user, vault)
      assert Map.has_key?(heads0, a.id)
      assert Map.has_key?(heads0, b.id)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{path: "H/A.md", content: "# A edited", mtime: 2_000.0})

      heads1 = CrdtTransport.vault_heads(user, vault)
      assert heads1[a.id].head != heads0[a.id].head, "edited note's head must advance"
      assert heads1[b.id].head == heads0[b.id].head, "untouched note's head must be stable"
    end

    test "each entry carries the note's DECRYPTED path alongside its head",
         %{user: user, vault: vault} do
      {:ok, a} =
        Notes.upsert_note(user, vault, %{path: "H/nested/A.md", content: "# A", mtime: 1_000.0})

      {:ok, b} = Notes.upsert_note(user, vault, %{path: "H/B.md", content: "# B", mtime: 1_000.0})

      heads = CrdtTransport.vault_heads(user, vault)

      assert %{path: "H/nested/A.md", head: ha} = heads[a.id]
      assert %{path: "H/B.md", head: hb} = heads[b.id]
      assert is_binary(ha) and byte_size(ha) > 0
      assert is_binary(hb) and byte_size(hb) > 0
    end

    test "a note with an undecryptable path is skipped, not fatal for the vault",
         %{user: user, vault: vault} do
      {:ok, good} =
        Notes.upsert_note(user, vault, %{path: "H/good.md", content: "# G", mtime: 1_000.0})

      {:ok, bad} =
        Notes.upsert_note(user, vault, %{path: "H/bad.md", content: "# B", mtime: 1_000.0})

      # Corrupt only the bad note's path ciphertext so its decrypt fails.
      {:ok, {1, nil}} =
        Repo.with_tenant(user.id, fn ->
          from(n in Note, where: n.id == ^bad.id)
          |> Repo.update_all(set: [path_ciphertext: <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>])
        end)

      heads = CrdtTransport.vault_heads(user, vault)

      assert %{path: "H/good.md"} = heads[good.id], "healthy notes still resolve"
      refute Map.has_key?(heads, bad.id), "the corrupt-path note is skipped"
    end

    test "returns a marker for every live note in the vault",
         %{user: user, vault: vault} do
      {:ok, a} = Notes.upsert_note(user, vault, %{path: "C/A.md", content: "# A", mtime: 1_000.0})
      {:ok, b} = Notes.upsert_note(user, vault, %{path: "C/B.md", content: "# B", mtime: 1_000.0})

      heads = CrdtTransport.vault_heads(user, vault)
      assert Map.has_key?(heads, a.id)
      assert Map.has_key?(heads, b.id)
      assert map_size(heads) == 2
    end

    test "returns an empty map when the DEK is unavailable, even with live notes" do
      user = insert(:user)
      refute user.encrypted_dek, "this user must have no DEK to exercise the no_dek branch"
      vault = insert(:vault, user: user)
      insert(:note, user: user, vault: vault)

      heads = CrdtTransport.vault_heads(user, vault)
      assert heads == %{}, "no DEK yields an empty head map"
    end
  end

  describe "crdt_head maintenance + vault_heads memory hardening" do
    test "a room edit invalidates a warmed crdt_head; vault_heads self-heals to the new head",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "MH/A.md", content: "# A\n\nseed", mtime: 1_000.0})

      on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

      # Warm the column so we can prove the edit INVALIDATES it (not just that a
      # never-set column stays NULL).
      _ = CrdtTransport.vault_heads(user, vault)
      {:ok, warmed} = Notes.get_note_by_id(user, vault, note.id)
      refute is_nil(warmed.crdt_head)

      {:ok, %{update: full}} = CrdtTransport.read_delta(user, vault, note.id, nil)
      client = CrdtBridge.new_doc()
      :ok = Yex.apply_update(client, full)
      before_sv = Yex.encode_state_vector!(client)
      CrdtBridge.ingest_plaintext(client, "# A\n\nseed and edit")
      {:ok, upd} = Yex.encode_state_as_update(client, before_sv)

      {:ok, %{head: head}} = CrdtTransport.apply_update(user, vault, note.id, upd)

      # The tail append (update_v1) invalidated the stale head...
      {:ok, invalidated} = Notes.get_note_by_id(user, vault, note.id)
      assert is_nil(invalidated.crdt_head), "a room edit must invalidate the cached head"

      # ...and vault_heads self-heals to the authoritative post-edit head.
      heads = CrdtTransport.vault_heads(user, vault)
      assert heads[note.id].head == head
    end

    test "vault_heads self-heals a NULL crdt_head and persists it for cheap re-reads",
         %{user: user, vault: vault} do
      {:ok, a} =
        Notes.upsert_note(user, vault, %{path: "MH/B.md", content: "# B", mtime: 1_000.0})

      # A freshly upserted note is INSERTed (the invalidation trigger is
      # BEFORE UPDATE, so it doesn't fire), so crdt_head starts NULL.
      {:ok, a0} = Notes.get_note_by_id(user, vault, a.id)
      assert is_nil(a0.crdt_head)

      heads = CrdtTransport.vault_heads(user, vault)
      assert is_binary(heads[a.id].head)

      {:ok, a1} = Notes.get_note_by_id(user, vault, a.id)
      assert a1.crdt_head == heads[a.id].head, "self-heal must persist the column"
    end

    test "vault_heads head equals read_delta's head for the same note",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "MH/C.md", content: "# C", mtime: 1_000.0})

      {:ok, %{head: rd_head}} = CrdtTransport.read_delta(user, vault, note.id, nil)
      heads = CrdtTransport.vault_heads(user, vault)
      assert heads[note.id].head == rd_head
    end

    test "a REST edit invalidates the head so vault_heads reflects the new state",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "MH/D.md", content: "# D\n\none", mtime: 1_000.0})

      heads0 = CrdtTransport.vault_heads(user, vault)
      h0 = heads0[note.id].head
      assert is_binary(h0)

      # A REST update rewrites crdt_state via maybe_merge_crdt; the trigger
      # nulls crdt_head so a stale head cannot survive the content change.
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          path: "MH/D.md",
          content: "# D\n\none two",
          mtime: 2_000.0
        })

      {:ok, mid} = Notes.get_note_by_id(user, vault, note.id)
      assert is_nil(mid.crdt_head), "trigger must invalidate crdt_head on a crdt_state change"

      heads1 = CrdtTransport.vault_heads(user, vault)
      assert heads1[note.id].head != h0, "head must advance after a REST edit"
    end

    test "backfill_head computes, persists, and returns a head matching read_delta",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "MH/E.md", content: "# E", mtime: 1_000.0})

      assert {:ok, head} = CrdtTransport.backfill_head(user, vault, note.id)
      {:ok, %{head: rd_head}} = CrdtTransport.read_delta(user, vault, note.id, nil)
      assert head == rd_head

      {:ok, reloaded} = Notes.get_note_by_id(user, vault, note.id)
      assert reloaded.crdt_head == head
    end

    test "backfill_head returns :not_found for an unknown note", %{user: user, vault: vault} do
      assert {:error, :not_found} =
               CrdtTransport.backfill_head(user, vault, Ecto.UUID.generate())
    end

    test "store_head_if_unchanged persists when the tail watermark still matches (CAS accept)",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          path: "MH/CAS1.md",
          content: "# C\n\nseed",
          mtime: 1_000.0
        })

      # Advance the tail so the watermark is a real row, then store against it.
      append_tail_row(user, vault, note.id)
      wm = CrdtTransport.tail_watermark(user, note.id)

      assert {:ok, {1, nil}} = CrdtTransport.store_head_if_unchanged(user, note.id, "HEADX", wm)
      {:ok, reloaded} = Notes.get_note_by_id(user, vault, note.id)
      assert reloaded.crdt_head == "HEADX"
    end

    test "store_head_if_unchanged does NOT persist when the tail advanced under it (CAS reject)",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          path: "MH/CAS2.md",
          content: "# C\n\none",
          mtime: 1_000.0
        })

      append_tail_row(user, vault, note.id)
      stale_wm = CrdtTransport.tail_watermark(user, note.id)

      # A concurrent edit appends another tail row AFTER the watermark was taken —
      # exactly the race the CAS guards. The self-heal's head (computed from the
      # pre-edit tail) must be refused (0 rows), leaving NULL for the next poll.
      append_tail_row(user, vault, note.id)

      assert {:ok, {0, nil}} =
               CrdtTransport.store_head_if_unchanged(user, note.id, "STALEHEAD", stale_wm)

      {:ok, reloaded} = Notes.get_note_by_id(user, vault, note.id)
      assert is_nil(reloaded.crdt_head), "a stale-watermark store must leave the column NULL"
    end

    test "any crdt_state_ciphertext write invalidates a warmed crdt_head (invalidation trigger)",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "MH/TRG.md", content: "# T", mtime: 1_000.0})

      _ = CrdtTransport.vault_heads(user, vault)
      {:ok, warmed} = Notes.get_note_by_id(user, vault, note.id)
      refute is_nil(warmed.crdt_head)

      # Rewrite crdt_state_ciphertext directly, exactly as checkpoint compaction
      # does — the BEFORE UPDATE OF crdt_state_ciphertext trigger must NULL
      # crdt_head, structurally covering the checkpoint snapshot writer (and any
      # future one), not just the REST maybe_merge_crdt path the round-trip test
      # exercises.
      {:ok, {1, nil}} =
        Repo.with_tenant(user.id, fn ->
          from(n in Note, where: n.id == ^note.id)
          |> Repo.update_all(set: [crdt_state_ciphertext: <<9, 9, 9>>])
        end)

      {:ok, reloaded} = Notes.get_note_by_id(user, vault, note.id)

      assert is_nil(reloaded.crdt_head),
             "a crdt_state write must invalidate the head via the trigger"
    end

    test "a crdt_head-only write does NOT fire the invalidation trigger (column-scoped)",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "MH/COL.md", content: "# C", mtime: 1_000.0})

      _ = CrdtTransport.vault_heads(user, vault)
      {:ok, warmed} = Notes.get_note_by_id(user, vault, note.id)
      head = warmed.crdt_head
      refute is_nil(head)

      # Writing ONLY crdt_head (as update_v1/store_head do) must not re-trip the
      # BEFORE UPDATE OF crdt_state_ciphertext trigger and null it back out.
      {:ok, {1, nil}} =
        Repo.with_tenant(user.id, fn ->
          from(n in Note, where: n.id == ^note.id)
          |> Repo.update_all(set: [crdt_head: "MANUAL"])
        end)

      {:ok, reloaded} = Notes.get_note_by_id(user, vault, note.id)
      assert reloaded.crdt_head == "MANUAL", "trigger must not fire on a crdt_head-only write"
    end
  end

  describe "safe_wire_frame?/1 (P0 #989 — WS state-vector DoS guard)" do
    test "non-step1 frames are always allowed (step2, update, non-sync)" do
      assert CrdtTransport.safe_wire_frame?(<<0, 1, 5>>), "syncStep2"
      assert CrdtTransport.safe_wire_frame?(<<0, 2, 9>>), "update"
      assert CrdtTransport.safe_wire_frame?(<<7, 7, 7>>), "not a sync message"
    end

    test "a real step1 frame built by the library's own encoder is allowed" do
      # Build the frame through y_ex's OWN encoder rather than hand-rolling the
      # varUint8Array prefix, so this pins the guard's length-prefix unwrap to
      # the actual library wire format — a future format drift breaks this test
      # instead of silently diverging. message_encode is a pure NIF (no
      # allocation bomb).
      sv = Yex.encode_state_vector!(CrdtBridge.new_doc())
      {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})
      assert <<0, 0, _::binary>> = frame
      assert CrdtTransport.safe_wire_frame?(frame)
    end

    test "a step1 with a crafted implausible state vector is rejected (never reaches the NIF)" do
      # DELIBERATELY DETERMINISTIC: <<128, 128, 128, 128, 15>> decodes as a
      # vector claiming ~2^31 client entries in 5 bytes. Random bytes here have
      # crashed the whole VM in the past; safe_wire_frame?/1 must reject via
      # pure byte math, never handing this to Yex.encode_state_as_update/2.
      malicious_sv = <<128, 128, 128, 128, 15>>
      frame = <<0, 0, byte_size(malicious_sv)>> <> malicious_sv
      refute CrdtTransport.safe_wire_frame?(frame)
    end

    test "a step1 whose length prefix claims more bytes than are present is rejected" do
      # Claims a 10-byte state vector but only 2 bytes follow the prefix.
      refute CrdtTransport.safe_wire_frame?(<<0, 0, 10, 1, 2>>)
    end

    test "a bare or empty-vector step1 fails closed" do
      refute CrdtTransport.safe_wire_frame?(<<0, 0>>)
      refute CrdtTransport.safe_wire_frame?(<<0, 0, 0>>)
    end
  end
end
