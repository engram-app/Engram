defmodule Engram.Workers.BackfillCrdtStateTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Crypto.Envelope
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, Note}
  alias Engram.Workers.BackfillCrdtState

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "BackfillCrdtStateTest", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  # Reproduces the post-2026-07-06 row shape: content present, CRDT state wiped.
  defp legacy_note(user, vault, path, content) do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content})

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note.id),
          set: [crdt_state_ciphertext: nil, crdt_state_nonce: nil]
        )
      end)

    note
  end

  # A GENUINE pre-T3.6 row: every envelope written with the EMPTY AAD and the
  # row stamped dek_version = 1, mirroring crypto/aad_rebind_test.exs. Stamping
  # v1 onto a row whose envelopes are already BOUND is not the same thing — such
  # a row fails maybe_decrypt_note_fields outright, so do_seed bails before it
  # can write anything and the test proves nothing.
  defp legacy_v1_note(user, vault, path, content) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    {:ok, hash_key} = Crypto.dek_content_hash_key(user)

    {content_ct, content_n} = Envelope.encrypt(content, dek)
    {title_ct, title_n} = Envelope.encrypt("legacy title", dek)
    {path_ct, path_n} = Envelope.encrypt(path, dek)
    {folder_ct, folder_n} = Envelope.encrypt("", dek)
    {tags_ct, tags_n} = Envelope.encrypt(:erlang.term_to_binary([]), dek)

    attrs = %{
      kind: "note",
      content_hash: Crypto.hmac_content_hash(hash_key, content),
      seq: 1,
      mtime: 0.0,
      version: 1,
      user_id: user.id,
      vault_id: vault.id,
      content_ciphertext: content_ct,
      content_nonce: content_n,
      title_ciphertext: title_ct,
      title_nonce: title_n,
      path_ciphertext: path_ct,
      path_nonce: path_n,
      path_hmac: Crypto.hmac_field(filter_key, path),
      folder_ciphertext: folder_ct,
      folder_nonce: folder_n,
      folder_hmac: Crypto.hmac_field(filter_key, ""),
      tags_ciphertext: tags_ct,
      tags_nonce: tags_n,
      tags_hmac: [],
      dek_version: Crypto.row_version_legacy()
    }

    {:ok, note} =
      Repo.with_tenant(user.id, fn ->
        %Note{}
        |> Ecto.Changeset.cast(attrs, Map.keys(attrs))
        |> Repo.insert!()
      end)

    note
  end

  defp reload(user, note_id) do
    {:ok, note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    note
  end

  test "seeds crdt_state from content so the note no longer binds empty", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "legacy.md", "IMPORTANT BODY")

    assert %Note{crdt_state_ciphertext: nil} = reload(user, note.id)

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    seeded = reload(user, note.id)
    refute is_nil(seeded.crdt_state_ciphertext)

    # The seeded state must project the real body — that is the whole point.
    {:ok, state} = Crypto.decrypt_crdt_state(seeded, user)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    assert CrdtBridge.text_of(doc) == "IMPORTANT BODY"
  end

  test "leaves content and version untouched — it backfills representation only", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "legacy.md", "BODY")
    before = reload(user, note.id)

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    seeded = reload(user, note.id)
    assert seeded.content == before.content
    assert seeded.content_hash == before.content_hash
    assert seeded.version == before.version
  end

  test "is idempotent — a note that already has state is left alone", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "fresh.md", "content" => "already seeded"})

    before = reload(user, note.id)
    refute is_nil(before.crdt_state_ciphertext)

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    # Byte-identical: the is_nil predicate must drop it, not re-seed it (a
    # re-seed would discard whatever CRDT history the row already holds).
    after_run = reload(user, note.id)
    assert after_run.crdt_state_ciphertext == before.crdt_state_ciphertext
    assert after_run.crdt_state_nonce == before.crdt_state_nonce
  end

  test "enqueue_all/0 enqueues only for pairs that still have a NULL-state note", ctx do
    %{user: user, vault: vault} = ctx
    _ = legacy_note(user, vault, "legacy.md", "BODY")

    assert BackfillCrdtState.enqueue_all() == 1

    assert_enqueued(worker: BackfillCrdtState, args: %{"user_id" => user.id})
  end

  test "enqueue_all/0 enqueues nothing when every note already has state", ctx do
    %{user: user, vault: vault} = ctx
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "fresh.md", "content" => "seeded"})

    assert BackfillCrdtState.enqueue_all() == 0
  end

  test "re-enqueues itself when a full batch means more remain", ctx do
    %{user: user, vault: vault} = ctx
    Application.put_env(:engram, :crdt_state_backfill_batch_size, 1)
    on_exit(fn -> Application.delete_env(:engram, :crdt_state_backfill_batch_size) end)

    _ = legacy_note(user, vault, "a.md", "A")
    _ = legacy_note(user, vault, "b.md", "B")

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    # A full batch must hand off to a successor, else the drain stops after one.
    assert_enqueued(worker: BackfillCrdtState, args: %{"user_id" => user.id})
  end

  test "after the backfill a legacy note binds with its body instead of empty", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_note(user, vault, "legacy.md", "IMPORTANT BODY")

    # Before: bind produces an EMPTY doc. Opening the note shows blank, and the
    # first keystroke gives the doc real state — at which point the checkpoint
    # legitimately materializes that keystroke over the whole body.
    empty_doc = CrdtBridge.new_doc()

    _ =
      CrdtPersistence.bind(
        %{user_id: user.id, vault_id: vault.id, note_id: note.id},
        note.id,
        empty_doc
      )

    assert CrdtBridge.text_of(empty_doc) == ""

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    # After: the same bind hydrates the real body. This is the guarantee the
    # removed seed_from_content used to provide, now provided by the DATA.
    healed = CrdtBridge.new_doc()

    _ =
      CrdtPersistence.bind(
        %{user_id: user.id, vault_id: vault.id, note_id: note.id},
        note.id,
        healed
      )

    assert CrdtBridge.text_of(healed) == "IMPORTANT BODY"
  end

  # #1341. Crypto.encrypt_crdt_state/3 binds the AAD to the row id
  # unconditionally, but decrypt_crdt_state/2 picks its AAD from the row's
  # dek_version. Seeding a dek_version = 1 row therefore wrote a ciphertext
  # nothing can read back — the mirror image of #1336 — and this is the exact
  # population the backfill targets, so it was reachable from the documented
  # repair rpc.
  test "migrates a legacy (dek_version = 1) row, then seeds it readably", ctx do
    %{user: user, vault: vault} = ctx
    note = legacy_v1_note(user, vault, "legacy-v1.md", "IMPORTANT BODY")

    assert :ok =
             perform_job(BackfillCrdtState, %{
               "user_id" => user.id,
               "vault_id" => vault.id,
               "cursor" => "00000000-0000-0000-0000-000000000000"
             })

    raw = reload(user, note.id)

    # The row must be migrated, not skipped. Skipping leaves crdt_state NULL,
    # which is the blank-open failure this worker exists to fix.
    assert raw.dek_version == Crypto.row_version_aad_bound()
    refute is_nil(raw.crdt_state_ciphertext)

    # And everything on it must be readable under the version it now claims —
    # a bound ciphertext on a row still claiming v1 is the #1336 shape.
    assert {:ok, state} = Crypto.decrypt_crdt_state(raw, user),
           """
           the backfill seeded an AAD-bound crdt_state onto a row still claiming
           dek_version=#{raw.dek_version}, so CrdtPersistence.bind/3 will raise
           and the note can no longer be opened or written at all.
           """

    assert {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(raw, user)
    assert decrypted.content == "IMPORTANT BODY"
    assert decrypted.path == "legacy-v1.md"

    # The seeded snapshot must project the real body, not an empty doc.
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    assert CrdtBridge.text_of(doc) == "IMPORTANT BODY"
  end
end
