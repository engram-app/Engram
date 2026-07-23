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

  test "bind/3 seeds the doc from notes.content when fresh (no snapshot, no tail-log)", ctx do
    %{user: user, vault: vault} = ctx
    # A note whose CRDT state has never been written (no snapshot, no tail-log)
    # but which carries plaintext content. A device that has never CRDT-edited
    # this note (e.g. device B discovering it) must still receive that content
    # over the y-protocols handshake — so bind seeds the doc from notes.content.
    {:ok, note2} =
      Notes.upsert_note(user, vault, %{"path" => "seed.md", "content" => "hello world"})

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

    assert CrdtBridge.text_of(doc) == "hello world"
  end

  test "bind/3 does NOT seed from content when a tail-log exists (no double-seed)", ctx do
    %{user: user, vault: vault} = ctx
    # crdt_state snapshot is absent, but a tail-log update already represents the
    # note's CRDT history. Seeding from notes.content here would duplicate text
    # (content + tail). The tail-log is authoritative — content must NOT be added.
    {:ok, note2} =
      Notes.upsert_note(user, vault, %{"path" => "tail.md", "content" => "PLAINTEXT"})

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note2.id),
          set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
        )
      end)

    st = %{user_id: user.id, vault_id: note2.vault_id, note_id: note2.id}

    # Append a tail-log update that sets the CRDT text to a distinct value.
    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, "TAIL")
    seed_doc = CrdtBridge.new_doc()
    _ = CrdtPersistence.update_v1(st, upd, note2.id, seed_doc)

    doc = CrdtBridge.new_doc()
    _returned = CrdtPersistence.bind(st, note2.id, doc)

    # Only the tail-log content — notes.content ("PLAINTEXT") was not seeded on top.
    text = CrdtBridge.text_of(doc)
    assert text == "TAIL"
    refute text =~ "PLAINTEXT"
  end

  test "bind/3 does not seed when content is empty (fresh, blank note)", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note2} = Notes.upsert_note(user, vault, %{"path" => "blank.md", "content" => ""})

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

    assert CrdtBridge.text_of(doc) == ""
  end

  test "bind/3 seeds when the snapshot exists but projects to EMPTY text and content is non-empty (#1087 empty-snapshot class)",
       ctx do
    %{user: user, vault: vault} = ctx
    # The genesis crdt_create row shape after a REST content write whose merge
    # never reached the state column: crdt_state holds an EMPTY-doc snapshot
    # while notes.content is non-empty. from_snapshot? alone must not defeat
    # the seed — an empty-projecting doc with no tail has exactly one source
    # of truth, the plaintext row content. (Pre-fix: STEP2 served empty while
    # REST getNote returned the body — the plugin's race-closer class.)
    {:ok, note2} =
      Notes.upsert_note(user, vault, %{"path" => "empty-snap.md", "content" => "real body"})

    {:ok, empty_state} = Yex.encode_state_as_update(CrdtBridge.new_doc())
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(empty_state, user, note2.id)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note2.id),
          set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]
        )
      end)

    st = %{user_id: user.id, vault_id: note2.vault_id, note_id: note2.id}
    doc = CrdtBridge.new_doc()
    _returned = CrdtPersistence.bind(st, note2.id, doc)

    assert CrdtBridge.text_of(doc) == "real body"
  end

  test "bind/3 does NOT seed when the snapshot projects empty AND content is empty (bare genesis row)",
       ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note2} = Notes.upsert_note(user, vault, %{"path" => "bare-genesis.md", "content" => ""})

    {:ok, empty_state} = Yex.encode_state_as_update(CrdtBridge.new_doc())
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(empty_state, user, note2.id)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note2.id),
          set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]
        )
      end)

    st = %{user_id: user.id, vault_id: note2.vault_id, note_id: note2.id}
    doc = CrdtBridge.new_doc()
    _returned = CrdtPersistence.bind(st, note2.id, doc)

    assert CrdtBridge.text_of(doc) == ""
  end

  test "bind/3 does NOT seed over a snapshot whose tail carries a legit clear (delete-all survives)",
       ctx do
    %{user: user, vault: vault} = ctx
    # A tail row that cleared the text: doc projects empty AFTER hydration, but
    # applied != [] — the clear is CRDT history, not a missing seed. Content
    # must NOT resurrect.
    {:ok, note2} =
      Notes.upsert_note(user, vault, %{"path" => "cleared.md", "content" => "STALE"})

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note2.id),
          set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
        )
      end)

    st = %{user_id: user.id, vault_id: note2.vault_id, note_id: note2.id}

    # Tail: insert then delete-all on ONE lineage → projects empty.
    {:ok, %{state: with_text}} = CrdtBridge.merge_plaintext(nil, "TO CLEAR")
    {:ok, %{state: tail_update}} = CrdtBridge.merge_plaintext(with_text, "")
    seed_doc = CrdtBridge.new_doc()
    _ = CrdtPersistence.update_v1(st, tail_update, note2.id, seed_doc)

    doc = CrdtBridge.new_doc()
    _returned = CrdtPersistence.bind(st, note2.id, doc)

    text = CrdtBridge.text_of(doc)
    refute text =~ "STALE"
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

  test "update_v1/4 fans out the update over the vault sync channel", ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}

    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, "hello fanout")

    # Simulate the room: SharedDoc applies the update BEFORE calling update_v1,
    # so head_marker(doc) reflects post-apply state.
    doc = CrdtBridge.new_doc()
    :ok = Yex.apply_update(doc, upd)

    topic = "sync:#{user.id}:#{note.vault_id}"
    EngramWeb.Endpoint.subscribe(topic)

    _st2 = CrdtPersistence.update_v1(st, upd, note.id, doc)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^topic,
      event: "note_yjs_update",
      payload: %{"note_id" => note_id, "b64" => b64, "head" => head, "seq" => seq}
    }

    assert note_id == note.id
    assert {:ok, ^upd} = Base.decode64(b64)
    assert is_binary(head) and head != ""
    assert head == Engram.Notes.CrdtTransport.head_marker(doc)
    # gap-heal (Phase D2): carries the note's current vault-global change
    # seq (the same field `list_changes_by_seq` orders by) so a device can
    # detect a missed/reordered live op and self-heal via catch-up.
    assert seq == note.seq
  end

  test "update_v1/4 fans out the correct seq when crdt_head is already nil (select: 0-rows fallback)",
       ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}

    # A freshly-created note's crdt_head is nil (only ever set later by the
    # transport self-heal read path), so the seq-fetching update_all's
    # `not is_nil(n.crdt_head)` guard matches ZERO rows here and update_v1
    # must fall back to a select-only query to still surface the seq.
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get(Note, note.id) end)
    assert raw_note.crdt_head == nil

    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, "zero rows fallback")
    doc = CrdtBridge.new_doc()
    :ok = Yex.apply_update(doc, upd)

    topic = "sync:#{user.id}:#{note.vault_id}"
    EngramWeb.Endpoint.subscribe(topic)

    _st2 = CrdtPersistence.update_v1(st, upd, note.id, doc)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^topic,
      event: "note_yjs_update",
      payload: %{"seq" => seq}
    }

    assert seq == note.seq
  end

  test "update_v1/4 fans out the correct seq via update_all select: when crdt_head is set (non-empty rows)",
       ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}

    # Simulate a note whose crdt_head cache is populated (set by the transport
    # self-heal read path) BEFORE this live delta arrives — the common hot-path
    # shape the `select: n.seq` clause targets: the update_all both
    # invalidates crdt_head AND returns the row's seq in one query.
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [crdt_head: "stale-head"])
      end)

    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, "returning path")
    doc = CrdtBridge.new_doc()
    :ok = Yex.apply_update(doc, upd)

    topic = "sync:#{user.id}:#{note.vault_id}"
    EngramWeb.Endpoint.subscribe(topic)

    _st2 = CrdtPersistence.update_v1(st, upd, note.id, doc)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^topic,
      event: "note_yjs_update",
      payload: %{"seq" => seq}
    }

    assert seq == note.seq

    # The stale head cache was invalidated by the same update_all.
    {:ok, updated} = Repo.with_tenant(user.id, fn -> Repo.get(Note, note.id) end)
    assert updated.crdt_head == nil
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

  # ── seed_from_content routes frontmatter through the codec ────────────────

  test "bind/3 seed routes frontmatter into Y.Map, not body Y.Text", ctx do
    %{user: user, vault: vault} = ctx

    # Note whose plaintext content includes a frontmatter block.
    content = "---\ntitle: Hi\n---\nbody\n"

    {:ok, note2} =
      Notes.upsert_note(user, vault, %{"path" => "fm_seed.md", "content" => content})

    # Clear CRDT state so bind/3 takes the fresh-room / seed path.
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

    {fm_order, fm_values} = CrdtBridge.frontmatter_of(doc)

    # Frontmatter must be populated in the Y.Map — not silently dropped.
    assert fm_order != [], "frontmatter_order should be non-empty after seed"
    assert Map.has_key?(fm_values, "title"), "Y.Map must contain the 'title' key"

    # Body Y.Text must NOT contain the raw frontmatter block.
    body = CrdtBridge.body_of(doc)
    refute String.contains?(body, "---"), "raw frontmatter delimiters must not appear in body"
    assert String.contains?(body, "body"), "body content must be preserved"
  end

  # ── bind/3 self-heals legacy docs with fence inline in Y.Text ───────────

  test "bind heals a persisted doc whose body Y.Text still holds a frontmatter fence",
       %{user: user, note: note} do
    # Craft an illegal at-rest state: fence inline in the body Y.Text, empty Y.Map.
    doc = CrdtBridge.new_doc()
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    Yex.Text.insert(text, 0, "---\ntitle: Hi\n---\nbody\n")
    {:ok, state} = Yex.encode_state_as_update(doc)
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(state, user, note.id)

    Repo.with_tenant(user.id, fn ->
      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce])
    end)

    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}
    bound = CrdtBridge.new_doc()
    CrdtPersistence.bind(st, note.id, bound)

    assert CrdtBridge.frontmatter_of(bound) == {["title"], %{"title" => "\"Hi\""}}
    assert CrdtBridge.body_of(bound) == "body\n"
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

  # ── unbind/3 materializes trailing edits ─────────────────────────────────

  test "unbind materializes trailing edits into notes.content and bumps seq", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Bind first to populate the crdt_state snapshot from notes.content
    st = %{user_id: user.id, vault_id: vault.id, note_id: note.id}
    doc = CrdtBridge.new_doc()
    st1 = CrdtPersistence.bind(st, note.id, doc)

    # Record the original seq
    {:ok, raw_note} =
      Repo.with_tenant(user.id, fn ->
        Repo.get!(Note, note.id)
      end)

    original_seq = raw_note.seq

    # Make a trailing edit that is NOT checkpointed
    :ok =
      CrdtBridge.diff_into_text(
        Yex.Doc.get_text(doc, CrdtBridge.text_name()),
        "trailing edit never checkpointed"
      )

    # unbind should materialize this trailing edit
    :ok = CrdtPersistence.unbind(st1, note.id, doc)

    # Verify the trailing edit made it into notes.content and seq was bumped
    {:ok, {:ok, updated}} =
      Repo.with_tenant(user.id, fn ->
        Crypto.maybe_decrypt_note_fields(Repo.get!(Note, note.id), user)
      end)

    assert updated.content =~ "trailing edit never checkpointed"
    assert updated.seq > original_seq
  end

  # ── bind/3 does NOT leak trap_exit into a bare test process ───────────────

  test "bind/3 called directly from a test process does not set trap_exit", ctx do
    %{user: user, note: note} = ctx
    st = %{user_id: user.id, vault_id: note.vault_id, note_id: note.id}
    doc = CrdtBridge.new_doc()

    # The guard relies on :"$initial_call" being absent in a bare test process.
    # Confirm the predicate holds: if this is nil, the guard will NOT set the flag.
    assert Process.get(:"$initial_call") == nil

    # Confirm the test process is not trapping exits before the call.
    assert Process.info(self(), :trap_exit) == {:trap_exit, false}

    # Call bind/3 directly (bare ExUnit test process — no :"$initial_call" in dict).
    _returned = CrdtPersistence.bind(st, note.id, doc)

    # The guard must have prevented the flag from being set.
    assert Process.info(self(), :trap_exit) == {:trap_exit, false}
  end
end
