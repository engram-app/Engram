defmodule Engram.Notes.CrdtMergePathTest do
  # async: false — these tests exercise the server-side CRDT merge path and
  # share the sandbox with other note modules; keep them serialized.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtPersistence, CrdtUpdateLog, Note}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "CrdtMerge", Ecto.UUID.generate())
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

  # Spec 0a (docs/superpowers/specs/2026-08-19-detached-writes-room-decoupling-design.md).
  #
  # A live-room checkpoint passes no `:prune_ids`, so it takes the WATERMARK
  # branch, which deletes every tail row at or below the watermark REGARDLESS of
  # whether the doc it snapshotted folded them.
  #
  # That is safe only while a room is the sole tail writer, because then its doc
  # provably reflects every row that exists. It is not a property of the
  # checkpoint; it is a property of who else is allowed to append. The moment a
  # second writer exists, a row landing after the room bound is snapshotted
  # by nobody and pruned by the watermark: gone from the tail AND absent from
  # crdt_state. That is the #285 class.
  #
  # Modelled here exactly as it happens: the room's doc is built from the
  # snapshot alone (what `bind/3` had at the time), and the row lands after.
  test "a tail row the checkpointed doc never folded is not pruned", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "unfolded.md", "content" => "BODY"})

    # The room's in-memory doc, as of its bind: snapshot only.
    raw = load_raw(user, note.id)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, live} = CrdtBridge.doc_from_state(state)

    # A second writer appends AFTER that bind. The room's doc cannot contain it.
    append_tail_update!(user, vault, note, " EXTRA")

    # The live-room checkpoint: no :prune_ids, so the watermark branch runs.
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, live)

    stored_text =
      user
      |> load_raw(note.id)
      |> then(fn r -> Crypto.decrypt_crdt_state(r, user) end)
      |> then(fn {:ok, s} -> s end)
      |> CrdtBridge.doc_from_state()
      |> then(fn {:ok, d} -> CrdtBridge.text_of(d) end)

    {:ok, surviving_tail} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count)
      end)

    # Either the snapshot absorbed it or the tail still holds it. Neither is
    # true today: the watermark pruned a row nothing folded.
    assert stored_text =~ "EXTRA" or surviving_tail > 0,
           """
           the checkpoint pruned a tail row its doc never folded.
           crdt_state projects #{inspect(stored_text)} and #{surviving_tail} tail
           row(s) remain, so the " EXTRA" update exists nowhere: the next bind
           replays an empty tail over a snapshot that never saw it. Unrecoverable.
           """
  end

  # The whole point of vault-scoping the tail reads (#1318). `notes.id` is a
  # primary key, so the same note_id cannot appear twice in `notes` — but
  # `crdt_update_log` rows carry their own id and a note_id COLUMN, so rows for
  # one note_id can be stamped with different vault_ids. That is the state
  # #1318 produced (do_bare_insert wrote global, read vault-scoped), and an
  # unscoped read folds the foreign vault's updates straight into this vault's
  # document.
  #
  # Written because the scoping change was otherwise UNTESTED against its own
  # purpose: no fixture produces this state naturally, so the whole suite stayed
  # green without ever exercising it.
  test "a tail row stamped with another vault is not folded into this vault's doc", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, other_vault, _} = Vaults.register_vault(user, "OtherVault", Ecto.UUID.generate())
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "scoped.md", "content" => "MINE"})

    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state("foreign_update", user, note.id)
    foreign_id = Ecto.UUID.generate()

    Repo.with_tenant(user.id, fn ->
      Repo.insert_all(CrdtUpdateLog, [
        %{
          id: foreign_id,
          note_id: note.id,
          user_id: user.id,
          vault_id: other_vault.id,
          update_ciphertext: ct,
          update_nonce: nonce,
          inserted_at: DateTime.utc_now()
        }
      ])
    end)

    {:ok, mine} =
      Repo.with_tenant(user.id, fn -> CrdtPersistence.tail_rows(note.id, vault.id) end)

    {:ok, theirs} =
      Repo.with_tenant(user.id, fn -> CrdtPersistence.tail_rows(note.id, other_vault.id) end)

    refute Enum.any?(mine, &(&1.id == foreign_id)),
           "a tail row belonging to another vault was returned for this vault's fold"

    assert Enum.any?(theirs, &(&1.id == foreign_id)),
           "the row vanished entirely — the filter is excluding its OWN vault too"
  end
end
