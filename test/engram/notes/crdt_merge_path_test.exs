defmodule Engram.Notes.CrdtMergePathTest do
  use Engram.DataCase, async: true

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, Note}

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
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "v1"})
    seq1 = Vaults.current_seq(user.id, vault.id)
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "v2"})
    seq2 = Vaults.current_seq(user.id, vault.id)
    assert seq2 > seq1
    assert n1.id != nil
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
end
