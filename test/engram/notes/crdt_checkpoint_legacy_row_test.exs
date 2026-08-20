defmodule Engram.Notes.CrdtCheckpointLegacyRowTest do
  @moduledoc """
  A checkpoint must never HALF-migrate a row's encryption (#1336).

  `Crypto.encrypt_crdt_state/3` always binds the AAD to the row id, so writing
  `crdt_state` forces `dek_version` up to the AAD-bound version. On a legacy
  (`dek_version = 1`) row the compaction and structural branches do exactly that
  while leaving content/title/path/folder/tags bound under the EMPTY AAD.

  After such a write `decrypt_aad/3` hands the bound AAD to v1 envelopes, so:

    * the note reads as `{:error, :decrypt_failed}`
    * `list_tree_notes` uses `PathCrypto.decrypt!`, so ONE such row 500s the
      whole vault tree, not just that note
    * `AadRebind` filters on the legacy `dek_version`, so it can no longer see
      the row to repair it

  Compaction runs on every room exit whose text is unchanged, so this is an
  ordinary path, not an exotic one. `do_rename_note_inner` documents the same
  hazard and re-encrypts everything; these branches were the exception.
  """
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, Envelope}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note}
  alias Engram.Repo

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "LegacyRow", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "a compaction does not half-migrate a legacy row", %{user: user, vault: vault} do
    body = "legacy body"
    note = insert_legacy_note!(user, vault, body)

    # Same text as the row, so the checkpoint takes the COMPACTION branch
    # (prev == content_hash): it writes crdt_state and nothing else.
    {:ok, doc} = CrdtBridge.doc_from_state(nil_state())
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), body)

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get(Note, note.id) end)

    # The row must still be internally consistent: whatever dek_version it
    # claims, every envelope on it must decrypt under that version.
    assert {:ok, fresh} = Crypto.maybe_decrypt_note_fields(raw, user),
           """
           the checkpoint half-migrated a legacy row: it stamped
           dek_version=#{raw.dek_version} while leaving the other envelopes
           bound under the empty AAD, so the note no longer decrypts at all.
           """

    assert fresh.content == body
    assert fresh.path == "legacy/path.md"
  end

  # The structural branch is the OTHER half of the guard, and it is the worse
  # half: markdown self-heals on the first real edit (materialize re-encrypts
  # every envelope) but nothing else ever writes a canvas note's state, so a
  # half-migrated legacy board is permanent. Without a test here the guard at
  # do_structural_checkpoint/5 can be refactored away with the suite still green.
  test "a structural (.canvas) checkpoint does not half-migrate a legacy row", %{
    user: user,
    vault: vault
  } do
    note = insert_legacy_note!(user, vault, "{}", path: "legacy/board.canvas")

    # Non-markdown path => checkpoint dispatches to do_structural_checkpoint/5,
    # which writes crdt_state and nothing else.
    {:ok, doc} = CrdtBridge.doc_from_state(nil_state())
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "{}")

    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get(Note, note.id) end)

    assert {:ok, fresh} = Crypto.maybe_decrypt_note_fields(raw, user),
           """
           the structural checkpoint half-migrated a legacy row: it stamped
           dek_version=#{raw.dek_version} while leaving the other envelopes
           bound under the empty AAD, so the board no longer decrypts and
           list_tree_notes raises for the WHOLE vault.
           """

    assert fresh.path == "legacy/board.canvas"
  end

  # An empty Yjs state, so doc_from_state builds a fresh doc.
  defp nil_state do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)
    {:ok, state} = Yex.encode_state_as_update(doc)
    state
  end

  # Every ciphertext column written with the EMPTY AAD, row stamped
  # dek_version = 1 — the shape AadRebind exists to migrate. Mirrors the
  # hand-built row in crypto/aad_rebind_test.exs.
  defp insert_legacy_note!(user, vault, body, opts \\ []) do
    path = Keyword.get(opts, :path, "legacy/path.md")

    {:ok, dek} = Crypto.get_dek(user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    {:ok, hash_key} = Crypto.dek_content_hash_key(user)

    {content_ct, content_n} = Envelope.encrypt(body, dek)
    {title_ct, title_n} = Envelope.encrypt("legacy title", dek)
    {path_ct, path_n} = Envelope.encrypt(path, dek)
    {folder_ct, folder_n} = Envelope.encrypt("legacy", dek)
    {tags_ct, tags_n} = Envelope.encrypt(:erlang.term_to_binary([]), dek)

    attrs = %{
      kind: "note",
      content_hash: Crypto.hmac_content_hash(hash_key, body),
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
      folder_hmac: Crypto.hmac_field(filter_key, "legacy"),
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
end
