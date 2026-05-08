defmodule Engram.Crypto.AadRebindTest do
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Engram.Crypto.{AadRebind, DekCache, Envelope}
  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, user: user}
  end

  describe "rebind_user/1" do
    test "rebinds a legacy note row to AAD-bound encryption", %{user: user} do
      # Use the real Vaults context so the vault is born AAD-bound (dek_version=2).
      # The rebind would otherwise pick it up and fail on the random-bytes
      # ciphertext the test factory writes.
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Rebind Vault"})
      {:ok, dek} = Crypto.get_dek(user)

      # Hand-build a legacy note: every ciphertext column written with
      # empty AAD; row stamped dek_version=1 (the column default).
      {content_ct, content_n} = Envelope.encrypt("legacy body", dek)
      {title_ct, title_n} = Envelope.encrypt("legacy title", dek)
      {path_ct, path_n} = Envelope.encrypt("legacy/path.md", dek)
      {folder_ct, folder_n} = Envelope.encrypt("legacy", dek)
      {tags_ct, tags_n} = Envelope.encrypt(:erlang.term_to_binary(["t1"]), dek)
      {:ok, filter_key} = Crypto.dek_filter_key(user)

      legacy_note =
        %Note{}
        |> Ecto.Changeset.cast(
          %{
            content_hash: "h",
            mtime: 0.0,
            user_id: user.id,
            vault_id: vault.id,
            content_ciphertext: content_ct,
            content_nonce: content_n,
            title_ciphertext: title_ct,
            title_nonce: title_n,
            path_ciphertext: path_ct,
            path_nonce: path_n,
            path_hmac: Crypto.hmac_field(filter_key, "legacy/path.md"),
            folder_ciphertext: folder_ct,
            folder_nonce: folder_n,
            folder_hmac: Crypto.hmac_field(filter_key, "legacy"),
            tags_ciphertext: tags_ct,
            tags_nonce: tags_n,
            tags_hmac: [Crypto.hmac_field(filter_key, "t1")],
            dek_version: 1
          },
          [
            :content_hash,
            :mtime,
            :user_id,
            :vault_id,
            :content_ciphertext,
            :content_nonce,
            :title_ciphertext,
            :title_nonce,
            :path_ciphertext,
            :path_nonce,
            :path_hmac,
            :folder_ciphertext,
            :folder_nonce,
            :folder_hmac,
            :tags_ciphertext,
            :tags_nonce,
            :tags_hmac,
            :dek_version
          ]
        )
        |> Repo.insert!(skip_tenant_check: true)

      assert legacy_note.dek_version == 1

      assert :ok = AadRebind.rebind_user(user.id)

      reloaded = Repo.reload!(legacy_note, skip_tenant_check: true)
      assert reloaded.dek_version == Crypto.row_version_aad_bound()

      # The rewritten ciphertext must decrypt under the bind AAD and FAIL
      # under empty AAD — proves the rebind actually changed the AAD slot.
      content_aad = Crypto.aad_for_row(:notes, :content, reloaded.id)

      assert {:ok, "legacy body"} =
               Envelope.decrypt(reloaded.content_ciphertext, reloaded.content_nonce, dek, content_aad)

      assert :error =
               Envelope.decrypt(reloaded.content_ciphertext, reloaded.content_nonce, dek, <<>>)

      # And the regular read path round-trips end-to-end.
      {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(reloaded, user)
      assert decrypted.content == "legacy body"
      assert decrypted.title == "legacy title"
      assert decrypted.path == "legacy/path.md"
      assert decrypted.folder == "legacy"
      assert decrypted.tags == ["t1"]
    end

    test "upgrades the user's wrapped DEK from v1 to v2 (AAD-bound)", %{user: user} do
      # ensure_user_dek already wrote a v2 wrap. Force a legacy v1 wrap to
      # exercise the rewrap path.
      master = Engram.Crypto.Config.local_master_key!()
      {:ok, dek} = Crypto.get_dek(user)
      {ct, nonce} = Envelope.encrypt(dek, master)
      legacy_v1 = <<0x01, 0x01, nonce::binary-size(12), ct::binary>>

      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [encrypted_dek: legacy_v1]],
        skip_tenant_check: true
      )

      assert :ok = AadRebind.rebind_user(user.id)

      reloaded = Repo.reload!(user)
      assert <<0x02, 0x01, _::binary>> = reloaded.encrypted_dek
    end

    test "is idempotent — second run returns :skipped (telemetry-wise) when no legacy rows remain",
         %{user: user} do
      {:ok, _vault} = Engram.Vaults.create_vault(user, %{name: "Idempotence Vault"})

      # Already at v2; first run rewraps DEK + finds no rows → succeeds.
      assert :ok = AadRebind.rebind_user(user.id)

      # Second run: DEK is now v2, no legacy rows → no-op.
      assert :ok = AadRebind.rebind_user(user.id)
    end
  end

  describe "rebind_all/1" do
    test "drives the cursor across multiple users", %{user: user_a} do
      user_b = insert(:user)
      {:ok, _} = Crypto.ensure_user_dek(user_b)

      counts = AadRebind.rebind_all(batch_size: 5)

      # Both users should have been processed without failures.
      assert counts.ok + counts.skipped >= 2
      assert counts.failed == 0
      _ = user_a
    end
  end

end
