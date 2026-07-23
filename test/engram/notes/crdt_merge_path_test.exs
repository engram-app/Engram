defmodule Engram.Notes.CrdtMergePathTest do
  # async: false — these tests exercise the server-side CRDT merge path and
  # share the sandbox with other note modules; keep them serialized.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtUpdateLog, Note}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtMerge"})
    %{user: user, vault: vault}
  end

  defp load_raw(user, id) do
    {:ok, {:ok, note}} = Repo.with_tenant(user.id, fn -> {:ok, Repo.get!(Note, id)} end)
    note
  end

  test "first write seeds crdt_state and content_hash matches merged text", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "hello"})

    raw = load_raw(user, note.id)
    refute is_nil(raw.crdt_state_ciphertext)
    refute is_nil(raw.crdt_state_nonce)

    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    assert CrdtBridge.text_of(doc) == "hello"

    # dek_version must be row_version_aad_bound so decrypt_crdt_state uses right AAD
    assert raw.dek_version == Crypto.row_version_aad_bound()

    {:ok, key} = Crypto.dek_content_hash_key(user)
    assert note.content_hash == Crypto.hmac_content_hash(key, "hello")
  end

  test "STALE-version write MERGES instead of 409ing — CRDT is the conflict resolution", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "shared base"})

    # Simulate a server-applied edit that bumps the row version out-of-band,
    # leaving the REST writer's `version` stale. The server edit is stored as
    # a CRDT state so future Yjs clients can merge convergently.
    raw = load_raw(user, note.id)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, %{state: server_state}} = CrdtBridge.merge_plaintext(state, "shared base + SERVER")
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(server_state, user, note.id)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        {:ok,
         Repo.update!(
           Note.changeset(raw, %{
             crdt_state_ciphertext: ct,
             crdt_state_nonce: nonce,
             version: note.version + 1
           })
         )}
      end)

    # REST writer pushes a diverging body under the NOW-STALE original version.
    # This MUST NOT return {:error, :version_conflict, _} — the key invariant
    # is "stale version → merge, not 409". Posture-C REST writers send full
    # plaintext, so the diff-based merge applies the client text as a diff onto
    # the server's CRDT state. The client's content wins the diff (its
    # plaintext overwrites as a minimal edit); the CRDT history retains the
    # server's prior operation for future Yjs clients to merge with apply_update.
    {:ok, note2} =
      Notes.upsert_note(user, vault, %{
        "path" => "a.md",
        "content" => "shared base + CLIENT",
        "version" => note.version
      })

    # The note was updated (no 409) and the client content is reflected.
    assert note2.content == "shared base + CLIENT"
    # The CRDT state was updated and decrypts cleanly.
    raw2 = load_raw(user, note2.id)
    assert {:ok, new_state} = Crypto.decrypt_crdt_state(raw2, user)
    {:ok, doc2} = CrdtBridge.doc_from_state(new_state)
    assert CrdtBridge.text_of(doc2) == "shared base + CLIENT"
  end

  test "a versionless write also merges (REST/MCP plaintext façade path)", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "alpha"})
    {:ok, note2} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "alpha beta"})
    assert note2.content == "alpha beta"
  end

  test "merge write bumps seq", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, _n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "v1"})
    seq1 = Vaults.current_seq(user.id, vault.id)
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "v2"})
    seq2 = Vaults.current_seq(user.id, vault.id)
    assert seq2 > seq1
  end

  test "decrypt round-trip: crdt_state written with row_version_aad_bound decrypts correctly",
       ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "rt.md", "content" => "roundtrip"})

    raw = load_raw(user, note.id)

    # Must have dek_version = row_version_aad_bound (2) so decrypt_crdt_state
    # uses AAD-bound key — otherwise it would try legacy <<>> AAD and fail.
    assert raw.dek_version == Crypto.row_version_aad_bound()

    # Decrypt must succeed and produce the content we wrote.
    assert {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    refute is_nil(state)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    assert CrdtBridge.text_of(doc) == "roundtrip"
  end

  test "content_hash reflects MERGED text, not the incoming payload", ctx do
    %{user: user, vault: vault} = ctx

    # Seed a note with "version one"
    {:ok, note1} =
      Notes.upsert_note(user, vault, %{"path" => "hash.md", "content" => "version one"})

    # Second write with the same base — verify content_hash is from merged result
    {:ok, note2} =
      Notes.upsert_note(user, vault, %{"path" => "hash.md", "content" => "version two"})

    {:ok, key} = Crypto.dek_content_hash_key(user)
    expected_hash = Crypto.hmac_content_hash(key, note2.content)
    assert note2.content_hash == expected_hash

    # The hashes differ because content changed
    refute note1.content_hash == note2.content_hash
  end

  test "REST write merges against snapshot + tail, not the stale snapshot alone", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "t.md", "content" => "shared base"})

    # Simulate live typing since the last checkpoint: a real Yjs update row in
    # the tail-log that appends " + LIVE" (build it from the note's snapshot doc,
    # capture the update with Yex.Doc.monitor_update_v1 — see this test file's
    # existing frame-building helpers).
    append_tail_update!(user, vault, note, " + LIVE")

    # REST writer read "shared base" (pre-live-typing) and appends its own edit.
    {:ok, updated} =
      Notes.upsert_note(user, vault, %{"path" => "t.md", "content" => "shared base + REST"})

    assert updated.content =~ "LIVE", "tail-log live edits must survive a REST merge"
    assert updated.content =~ "REST"
  end

  test "nil-snapshot with tail rows merges without duplicating the body", ctx do
    %{user: user, vault: vault} = ctx

    # Create a note so we have a valid note_id, vault_id, etc.
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "nil-snap.md", "content" => "placeholder"})

    # NULL out the crdt_state columns to simulate a pre-CRDT note (bind/3's seed
    # path: no snapshot + a tail update seeded from an empty doc).
    Repo.with_tenant(user.id, fn ->
      {:ok,
       Repo.update_all(
         from(n in Engram.Notes.Note, where: n.id == ^note.id),
         set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
       )}
    end)

    # Simulate bind/3's seed_from_content path: it starts from a FRESH empty doc
    # and ingests the full text — producing a tail row that encodes the full body
    # as an insert-everything operation relative to the empty doc.
    seed_doc = CrdtBridge.new_doc()
    {:ok, _ref} = Yex.Doc.monitor_update_v1(seed_doc)
    text = Yex.Doc.get_text(seed_doc, CrdtBridge.text_name())
    :ok = CrdtBridge.diff_into_text(text, "shared base + LIVE")

    seed_update =
      receive do
        {:update_v1, update, _origin, ^seed_doc} -> update
      after
        1_000 -> raise "timeout waiting for seed update_v1"
      end

    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(seed_update, user, note.id)

    Repo.with_tenant(user.id, fn ->
      Repo.insert_all(CrdtUpdateLog, [
        %{
          id: Ecto.UUID.generate(),
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        }
      ])
    end)

    # REST writer arrives with the same base text (before the LIVE edit).
    {:ok, updated} =
      Notes.upsert_note(user, vault, %{"path" => "nil-snap.md", "content" => "shared base + REST"})

    # "shared base" must appear exactly once — not doubled ("shared base + RESTshared base + LIVE")
    assert length(String.split(updated.content, "shared base")) == 2,
           "body was duplicated: #{inspect(updated.content)}"

    refute String.contains?(updated.content, "RESTshared"),
           "duplication detected: #{inspect(updated.content)}"
  end

  test "EMPTY-projecting snapshot with tail rows merges without duplicating the body (#1087 sibling)",
       ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "empty-snap-dup.md", "content" => "placeholder"})

    # Set crdt_state to an encrypted EMPTY-doc snapshot (the genesis shape) —
    # NOT nil. Pre-fix, maybe_merge_crdt took the three-way leg with an empty
    # ancestor: the incoming diff became insert-everything and unioned with the
    # bind-seeded tail into a doubled body.
    {:ok, empty_state} = Yex.encode_state_as_update(CrdtBridge.new_doc())
    {:ok, {ect, enonce}} = Crypto.encrypt_crdt_state(empty_state, user, note.id)

    Repo.with_tenant(user.id, fn ->
      {:ok,
       Repo.update_all(
         from(n in Engram.Notes.Note, where: n.id == ^note.id),
         set: [crdt_state_ciphertext: ect, crdt_state_nonce: enonce]
       )}
    end)

    # Bind-time seed lineage in the tail: full text inserted against an empty doc.
    seed_doc = CrdtBridge.new_doc()
    {:ok, _ref} = Yex.Doc.monitor_update_v1(seed_doc)
    text = Yex.Doc.get_text(seed_doc, CrdtBridge.text_name())
    :ok = CrdtBridge.diff_into_text(text, "shared base + LIVE")

    seed_update =
      receive do
        {:update_v1, update, _origin, ^seed_doc} -> update
      after
        1_000 -> raise "timeout waiting for seed update_v1"
      end

    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(seed_update, user, note.id)

    Repo.with_tenant(user.id, fn ->
      Repo.insert_all(CrdtUpdateLog, [
        %{
          id: Ecto.UUID.generate(),
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        }
      ])
    end)

    {:ok, updated} =
      Notes.upsert_note(user, vault, %{
        "path" => "empty-snap-dup.md",
        "content" => "shared base + REST"
      })

    assert length(String.split(updated.content, "shared base")) == 2,
           "body was duplicated: #{inspect(updated.content)}"

    refute String.contains?(updated.content, "RESTshared"),
           "duplication detected: #{inspect(updated.content)}"
  end

  # Inserts one synthetic Yjs update row into the tail-log for the given note.
  # The update extends the snapshot doc's text by appending `suffix`.
  # Steps:
  #   1. Decrypt the note's current snapshot → doc.
  #   2. Monitor the doc for update_v1 events.
  #   3. Diff the extended text into the doc (captures one update binary).
  #   4. Encrypt the update binary and insert a CrdtUpdateLog row.
  defp append_tail_update!(user, vault, note, suffix) do
    raw = load_raw(user, note.id)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)

    {:ok, _ref} = Yex.Doc.monitor_update_v1(doc)

    current_text = CrdtBridge.body_of(doc)
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    :ok = CrdtBridge.diff_into_text(text, current_text <> suffix)

    update =
      receive do
        {:update_v1, update, _origin, ^doc} -> update
      after
        1_000 -> raise "timeout waiting for update_v1 from doc mutation"
      end

    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(update, user, note.id)

    Repo.with_tenant(user.id, fn ->
      Repo.insert_all(CrdtUpdateLog, [
        %{
          id: Ecto.UUID.generate(),
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        }
      ])
    end)

    :ok
  end
end
