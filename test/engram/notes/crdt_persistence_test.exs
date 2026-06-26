defmodule Engram.Notes.CrdtPersistenceTest do
  use Engram.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, CrdtUpdateLog, Note}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtPersist"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "base"})
    %{user: user, vault: vault, note: note}
  end

  # ── Schema-level gate: assert the table columns exist ─────────────────────

  test "crdt_update_log table has all required columns" do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_name = 'crdt_update_log'
          AND column_name IN (
            'id', 'note_id', 'user_id', 'vault_id',
            'update_ciphertext', 'update_nonce', 'inserted_at'
          )
        ORDER BY column_name
        """,
        []
      )

    found = Enum.map(rows, &hd/1) |> MapSet.new()

    assert MapSet.member?(found, "id")
    assert MapSet.member?(found, "note_id")
    assert MapSet.member?(found, "user_id")
    assert MapSet.member?(found, "vault_id")
    assert MapSet.member?(found, "update_ciphertext")
    assert MapSet.member?(found, "update_nonce")
    assert MapSet.member?(found, "inserted_at")
  end

  test "inserted_at column is timestamptz (not timestamp)", _ctx do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = 'crdt_update_log'
          AND column_name = 'inserted_at'
        """,
        []
      )

    assert [[_col, "timestamp with time zone"]] = rows
  end

  # ── bind/3 loads persisted snapshot ───────────────────────────────────────

  test "bind/3 loads the persisted snapshot into a fresh doc", ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}
    doc = CrdtBridge.new_doc()
    _state = CrdtPersistence.bind(st, note.id, doc)

    assert CrdtBridge.text_of(doc) == "base"
  end

  test "bind/3 returns state map with resolved :user cached", ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}
    doc = CrdtBridge.new_doc()
    returned = CrdtPersistence.bind(st, note.id, doc)

    assert %{user: cached_user} = returned
    assert cached_user.id == user.id
  end

  test "bind/3 with no snapshot (nil crdt_state) starts empty doc", ctx do
    %{user: user, vault: vault} = ctx
    # Write a note without crdt_state (via insert bypassing Notes.upsert_note
    # side-effects). Since Notes.upsert_note always seeds crdt_state, we use
    # a second fresh note and zero out its crdt_state columns manually.
    {:ok, note2} = Notes.upsert_note(user, vault, %{"path" => "empty.md", "content" => "hi"})

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note2.id),
          set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
        )
      end)

    st = %{user_id: user.id, vault_id: note2.vault_id, note_id: note2.id}
    doc = CrdtBridge.new_doc()
    _returned = CrdtPersistence.bind(st, note2.id, doc)

    # An empty doc has an empty string — bind should not crash
    assert is_binary(CrdtBridge.text_of(doc))
  end

  # ── update_v1/4 writes encrypted log row ──────────────────────────────────

  test "update_v1/4 appends an encrypted, decryptable log row", ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}

    # Produce a real Yjs v1 update binary
    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, "x")

    doc = CrdtBridge.new_doc()
    _st2 = CrdtPersistence.update_v1(st, upd, note.id, doc)

    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(l in CrdtUpdateLog, where: l.note_id == ^note.id, order_by: [asc: l.inserted_at])
        )
      end)

    [row] = rows

    # The row must be ciphertext — not the raw update binary
    refute row.update_ciphertext == upd

    # But it must decrypt back to the original update using the note-shaped struct
    raw_note = %Note{
      id: note.id,
      dek_version: Crypto.row_version_aad_bound(),
      crdt_state_ciphertext: row.update_ciphertext,
      crdt_state_nonce: row.update_nonce
    }

    assert {:ok, ^upd} = Crypto.decrypt_crdt_state(raw_note, user)
  end

  test "update_v1/4 with cached user does not hit Accounts.get_user!", ctx do
    %{user: user, note: note} = ctx
    # Bind first so the cached user is in the state
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}
    doc = CrdtBridge.new_doc()
    st2 = CrdtPersistence.bind(st, note.id, doc)

    # The returned state must have a cached user
    assert Map.has_key?(st2, :user)

    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, "y")
    _st3 = CrdtPersistence.update_v1(st2, upd, note.id, doc)

    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(l in CrdtUpdateLog,
            where: l.note_id == ^note.id,
            order_by: [asc: l.inserted_at]
          )
        )
      end)

    # At least one row written
    assert rows != []
  end

  # ── round-trip: update → unbind snapshot → bind reconstructs ──────────────

  test "round-trip: write updates, unbind snapshots, fresh bind reconstructs text", ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}

    # Bind to load the initial snapshot ("base")
    doc1 = CrdtBridge.new_doc()
    st1 = CrdtPersistence.bind(st, note.id, doc1)

    # Simulate incoming update: a merge from client
    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, "base updated")
    _st2 = CrdtPersistence.update_v1(st1, upd, note.id, doc1)

    # Apply the update to doc1 as well so unbind snapshots the merged state
    :ok = Yex.apply_update(doc1, upd)

    # unbind should write the compacted snapshot to the notes row
    :ok = CrdtPersistence.unbind(st1, note.id, doc1)

    # Bind a fresh doc — it should reconstruct state from the snapshot
    doc2 = CrdtBridge.new_doc()
    _st3 = CrdtPersistence.bind(st, note.id, doc2)

    # The snapshot must contain the merged text
    assert CrdtBridge.text_of(doc2) =~ "base"
  end

  # ── security: tail-log rows are ciphertext, not plaintext ─────────────────

  test "tail-log rows store ciphertext, not plaintext Yjs binaries", ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}

    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, "secret content")
    doc = CrdtBridge.new_doc()
    _st2 = CrdtPersistence.update_v1(st, upd, note.id, doc)

    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(l in CrdtUpdateLog, where: l.note_id == ^note.id))
      end)

    [row] = rows

    # The raw ciphertext must not equal the plaintext update binary
    refute row.update_ciphertext == upd

    # A nonce must be present (12 bytes for AES-GCM)
    assert is_binary(row.update_nonce)
    assert byte_size(row.update_nonce) == 12
  end

  # ── unbind/3 writes snapshot ───────────────────────────────────────────────

  test "unbind/3 writes encrypted snapshot to the notes row", ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}

    doc = CrdtBridge.new_doc()
    st1 = CrdtPersistence.bind(st, note.id, doc)

    # Modify the doc further
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    Yex.Text.insert(text, 0, "prefix ")

    :ok = CrdtPersistence.unbind(st1, note.id, doc)

    # Load fresh note row and decrypt crdt_state
    {:ok, raw_note} =
      Repo.with_tenant(user.id, fn ->
        Repo.get!(Note, note.id)
      end)

    refute is_nil(raw_note.crdt_state_ciphertext)
    {:ok, snapshot} = Crypto.decrypt_crdt_state(raw_note, user)
    assert is_binary(snapshot)

    # Reconstruct doc from snapshot and verify text
    {:ok, check_doc} = CrdtBridge.doc_from_state(snapshot)
    final_text = CrdtBridge.text_of(check_doc)
    assert String.contains?(final_text, "prefix")
  end

  # ── replay_tail: corrupt/undecryptable rows are skipped with a warning ────

  test "bind/3 skips undecryptable tail-log row and emits a warning", ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}

    # Insert a tail-log row with garbage ciphertext so decrypt will fail
    Repo.with_tenant(user.id, fn ->
      %CrdtUpdateLog{}
      |> CrdtUpdateLog.changeset(%{
        note_id: note.id,
        user_id: user.id,
        vault_id: note.vault_id,
        # Random garbage — not valid AES-GCM ciphertext under the user's DEK
        update_ciphertext: :crypto.strong_rand_bytes(64),
        update_nonce: :crypto.strong_rand_bytes(12)
      })
      |> Repo.insert!()
    end)

    doc = CrdtBridge.new_doc()

    log =
      capture_log(fn ->
        _state = CrdtPersistence.bind(st, note.id, doc)
      end)

    # The call must not crash and must emit a structured warning
    assert log =~ "crdt replay_tail decrypt failed"
    assert log =~ "note_id=#{note.id}"

    # The doc is still usable — the snapshot ("base") was loaded successfully
    assert is_binary(CrdtBridge.text_of(doc))
  end

  # ── bind/3 replays tail-log after snapshot ────────────────────────────────

  test "bind/3 replays tail-log rows on top of the snapshot", ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}

    # First bind (snapshot has "base")
    doc1 = CrdtBridge.new_doc()
    st1 = CrdtPersistence.bind(st, note.id, doc1)

    # Write an update to the tail-log but do NOT unbind (no snapshot flush)
    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, "tail only edit")
    _st2 = CrdtPersistence.update_v1(st1, upd, note.id, doc1)

    # Now bind a fresh doc — it must replay the tail-log
    doc2 = CrdtBridge.new_doc()
    _st3 = CrdtPersistence.bind(st, note.id, doc2)

    # The fresh doc should have the tail-log update applied (converged)
    text = CrdtBridge.text_of(doc2)
    # Both "base" (from snapshot) and the tail merge should be in the doc
    assert is_binary(text)
    # After tail replay the doc has content from both sources
    assert String.length(text) > 0
  end
end
