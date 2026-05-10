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
               Envelope.decrypt(
                 reloaded.content_ciphertext,
                 reloaded.content_nonce,
                 dek,
                 content_aad
               )

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

    test "is idempotent — second run returns :skipped when no legacy rows remain (T3-audit M3)",
         %{user: user} do
      # T3-audit M3 — pre-fix, every successful run returned :ok regardless
      # of whether rows were actually rebound. An operator drain log saying
      # `%{ok: 1000, skipped: 0}` couldn't distinguish "1000 rebinds happened"
      # from "1000 users had nothing to do." Fix: track whether the wrap was
      # changed AND whether any rows were rewritten. If neither, return
      # :skipped so re-runs are honest.
      {:ok, _vault} = Engram.Vaults.create_vault(user, %{name: "Idempotence Vault"})

      # First run: DEK wrap upgrades v1→v2 + Idempotence Vault was just
      # created (post-T3.6 already at v2 if factories track it; the rewrap
      # itself counts as "did work"). Either way, returns :ok or :skipped
      # depending on factory state — we tolerate both.
      first = AadRebind.rebind_user(user.id)
      assert first in [:ok, :skipped]

      # Second run: wrap is now v2, no legacy rows remain → MUST be :skipped.
      assert :skipped = AadRebind.rebind_user(user.id),
             "rebind_user/1 must return :skipped when nothing changes — operator drain logs depend on it"
    end
  end

  describe "attachment rebind honesty (T3-audit H5)" do
    test "emits :attachment_skipped telemetry per user with legacy count", %{user: user} do
      # T3-audit H5 — attachment rebind is intentionally a no-op (S3 blob's
      # AAD doesn't get touched here; converges on next upload). Pre-fix,
      # rebind_user_attachments/1 returned :ok with no signal, so an
      # operator drain log told them attachments were rebound when they
      # weren't. Fix: emit per-user telemetry with the count of legacy
      # attachments that still need natural convergence.
      legacy_version = Crypto.row_version_legacy()

      # Use the real Vaults context so the vault is born AAD-bound; we want
      # to isolate this test to the attachment rebind signal, not vault
      # legacy decrypt.
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Attachment Vault"})

      _att1 = insert(:attachment, user: user, vault: vault, dek_version: legacy_version)
      _att2 = insert(:attachment, user: user, vault: vault, dek_version: legacy_version)

      :telemetry.attach(
        "att-skipped-test",
        [:engram, :crypto, :aad_rebind, :attachment_skipped],
        fn _name, measurements, metadata, _ ->
          send(self(), {:attachment_skipped, measurements, metadata})
        end,
        nil
      )

      try do
        AadRebind.rebind_user(user.id)

        assert_received {:attachment_skipped, %{count: count}, %{user_id: uid}}
        assert uid == user.id

        assert count >= 2,
               "telemetry must report legacy attachment count so operators can plan natural convergence; got #{count}"
      after
        :telemetry.detach("att-skipped-test")
      end
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

  describe "Logger on failure (T3-audit H4)" do
    test "rebind_user logs error with user_id + reason_label when txn fails" do
      # T3-audit H4 — failed per-user rebinds were emitting telemetry only.
      # Combined with H2 (no registered telemetry handlers), per-user
      # failures during a backfill drain were operationally invisible:
      # operator sees `%{failed: 7}` aggregate with no user_ids and no
      # reasons, no way to triage stuck users.
      bogus_id = -42

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:not_found, ^bogus_id}} = AadRebind.rebind_user(bogus_id)
        end)

      assert log =~ "aad rebind failed",
             "expected `aad rebind failed` log line, got: #{log}"

      assert log =~ "user_id=#{bogus_id}",
             "log must carry user_id for triage, got: #{log}"

      assert log =~ "reason_label=not_found",
             "log must carry reason_label so operators can group failures, got: #{log}"
    end
  end
end
