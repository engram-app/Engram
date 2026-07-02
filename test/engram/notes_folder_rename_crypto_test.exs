defmodule Engram.NotesFolderRenameCryptoTest do
  @moduledoc """
  Folder rename crypto scope (#863). For AAD-bound rows (dek_version 2) the
  content AAD (`notes:content:<id>`) does not change on a rename, and a
  folder rename preserves the basename so the title cannot change either —
  only the path + folder envelopes need re-encryption. The old path
  re-encrypted EVERY column including the content blob: wasted AES-GCM plus
  a TOAST/WAL rewrite of the largest column on every note in the folder.

  Legacy v1 rows (empty AAD) still get the full rebind — the rename is
  their upgrade opportunity to AAD-bound encryption.
  """
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp raw_row(user, id) do
    {:ok, row} = Repo.with_tenant(user.id, fn -> Repo.get(Notes.Note, id) end)
    row
  end

  test "rename does not rewrite content/tags ciphertext on AAD-bound rows", %{
    user: user,
    vault: vault
  } do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "Old/a.md",
        "content" => "---\ntags: [keep]\n---\n# Heading\n\nbody"
      })

    before = raw_row(user, note.id)
    assert before.dek_version == Engram.Crypto.row_version_aad_bound()

    {:ok, _} = Notes.rename_folder(user, vault, "Old", "New")

    after_row = raw_row(user, note.id)
    assert after_row.content_ciphertext == before.content_ciphertext
    assert after_row.tags_ciphertext == before.tags_ciphertext
    # Path + folder envelopes DID rotate.
    refute after_row.path_ciphertext == before.path_ciphertext
    refute after_row.folder_ciphertext == before.folder_ciphertext

    # And the note still reads back fully intact at the new path.
    {:ok, read} = Notes.get_note(user, vault, "New/a.md")
    assert read.content =~ "body"
    assert read.title == "Heading"
    assert read.tags == ["keep"]
    assert read.folder == "New"
  end

  test "legacy v1 rows still get the full AAD rebind on rename", %{
    user: user,
    vault: vault
  } do
    # Hand-build a v1 (empty-AAD) row the way AadRebind tests do, then
    # rename its folder and expect a v2 row that reads back cleanly.
    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    {:ok, content_key} = Engram.Crypto.dek_content_hash_key(user)
    alias Engram.Crypto.Envelope

    content = "# Legacy\n\nold body"
    {content_ct, content_n} = Envelope.encrypt(content, dek)
    {title_ct, title_n} = Envelope.encrypt("Legacy", dek)
    {path_ct, path_n} = Envelope.encrypt("Old/legacy.md", dek)
    {folder_ct, folder_n} = Envelope.encrypt("Old", dek)
    {tags_ct, tags_n} = Envelope.encrypt(:erlang.term_to_binary([]), dek)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.insert!(%Notes.Note{
          id: Ecto.UUID.generate(),
          version: 1,
          seq: Engram.Vaults.next_seq!(vault.id),
          content_hash: Engram.Crypto.hmac_content_hash(content_key, content),
          mtime: 0.0,
          user_id: user.id,
          vault_id: vault.id,
          dek_version: 1,
          content_ciphertext: content_ct,
          content_nonce: content_n,
          title_ciphertext: title_ct,
          title_nonce: title_n,
          path_ciphertext: path_ct,
          path_nonce: path_n,
          path_hmac: Engram.Crypto.hmac_field(filter_key, "Old/legacy.md"),
          folder_ciphertext: folder_ct,
          folder_nonce: folder_n,
          folder_hmac: Engram.Crypto.hmac_field(filter_key, "Old"),
          tags_ciphertext: tags_ct,
          tags_nonce: tags_n,
          tags_hmac: []
        })
      end)

    {:ok, _} = Notes.rename_folder(user, vault, "Old", "New")

    {:ok, read} = Notes.get_note(user, vault, "New/legacy.md")
    assert read.content == content
    assert read.dek_version == Engram.Crypto.row_version_aad_bound()
  end
end
