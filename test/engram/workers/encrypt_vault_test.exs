defmodule Engram.Workers.EncryptVaultTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Repo
  alias Engram.Notes.Note
  alias Engram.Vaults.Vault
  alias Engram.Workers.EncryptVault

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
    end)

    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
      {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
    end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)

    vault =
      insert(:vault,
        user: user,
        encrypted: true,
        encryption_status: "encrypting",
        last_toggle_at: DateTime.utc_now()
      )

    %{bypass: bypass, user: user, vault: vault}
  end

  defp stub_qdrant_set_payload(bypass) do
    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)
  end

  describe "perform/1" do
    test "no-ops when vault is not in encrypting status", %{vault: vault, user: user} do
      {:ok, vault} = Vault.update_status(vault, "encrypted")

      assert :ok =
               perform_job(EncryptVault, %{
                 "vault_id" => vault.id,
                 "user_id" => user.id,
                 "cursor" => 0
               })
    end

    test "encrypts notes in batch and stamps ciphertext columns", %{
      bypass: bypass,
      vault: vault,
      user: user
    } do
      stub_qdrant_set_payload(bypass)

      note =
        Engram.Fixtures.insert_note!(user, vault,
          content: "secret body",
          title: "Top Secret"
        )

      assert :ok =
               perform_job(EncryptVault, %{
                 "vault_id" => vault.id,
                 "user_id" => user.id,
                 "cursor" => 0
               })

      reloaded = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert reloaded.content_ciphertext != nil
      assert reloaded.content_nonce != nil
      assert reloaded.title_ciphertext != nil
    end

    test "finalizes vault to encrypted when batch is under 100", %{
      bypass: bypass,
      vault: vault,
      user: user
    } do
      stub_qdrant_set_payload(bypass)
      Engram.Fixtures.insert_note!(user, vault, content: "x")

      :ok =
        perform_job(EncryptVault, %{
          "vault_id" => vault.id,
          "user_id" => user.id,
          "cursor" => 0
        })

      updated = Repo.get!(Vault, vault.id, skip_tenant_check: true)
      assert updated.encryption_status == "encrypted"
      assert updated.encrypted_at != nil
    end

    test "re-enqueues with new cursor when batch is full", %{
      bypass: bypass,
      vault: vault,
      user: user
    } do
      stub_qdrant_set_payload(bypass)
      # Insert 100 notes — full batch.
      for i <- 1..100 do
        Engram.Fixtures.insert_note!(user, vault, content: "note-#{i}", path: "n/#{i}.md")
      end

      :ok =
        perform_job(EncryptVault, %{
          "vault_id" => vault.id,
          "user_id" => user.id,
          "cursor" => 0
        })

      # Should NOT finalize — batch was full, more work remains.
      updated = Repo.get!(Vault, vault.id, skip_tenant_check: true)
      assert updated.encryption_status == "encrypting"

      # Should re-enqueue with new cursor.
      assert_enqueued(worker: EncryptVault)
    end

    test "emits :note_encrypted and :vault_encrypted telemetry", %{
      bypass: bypass,
      vault: vault,
      user: user
    } do
      stub_qdrant_set_payload(bypass)
      Engram.Fixtures.insert_note!(user, vault, content: "x")

      test_pid = self()

      :telemetry.attach_many(
        "test-encrypt-telemetry",
        [
          [:engram, :crypto, :backfill, :note_encrypted],
          [:engram, :crypto, :backfill, :vault_encrypted]
        ],
        fn name, _m, meta, _c -> send(test_pid, {:telemetry, name, meta}) end,
        nil
      )

      :ok =
        perform_job(EncryptVault, %{
          "vault_id" => vault.id,
          "user_id" => user.id,
          "cursor" => 0
        })

      assert_receive {:telemetry, [:engram, :crypto, :backfill, :note_encrypted], _}, 500
      assert_receive {:telemetry, [:engram, :crypto, :backfill, :vault_encrypted], _}, 500

      :telemetry.detach("test-encrypt-telemetry")
    end
  end
end
