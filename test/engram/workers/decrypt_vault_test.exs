defmodule Engram.Workers.DecryptVaultTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.Repo
  alias Engram.Notes.Note
  alias Engram.Vaults.Vault
  alias Engram.Workers.DecryptVault

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    # Global embedder stub — worker re-indexes via Engram.Indexing.
    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
    end)

    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
      {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
    end)

    user = insert(:user)

    vault =
      insert(:vault,
        user: user,
        encrypted: true,
        encryption_status: "decrypt_pending",
        decrypt_requested_at: DateTime.utc_now(),
        last_toggle_at: DateTime.utc_now()
      )

    %{bypass: bypass, user: user, vault: vault}
  end

  defp stub_qdrant(bypass) do
    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)
  end

  describe "perform/1" do
    test "no-ops when vault is in encrypted state (cancelled)", %{user: user, vault: vault} do
      {:ok, vault} = Vault.update_status(vault, "encrypted")

      assert :ok =
               perform_job(DecryptVault, %{
                 "vault_id" => vault.id,
                 "user_id" => user.id,
                 "cursor" => 0
               })

      reloaded = Repo.get!(Vault, vault.id, skip_tenant_check: true)
      assert reloaded.encryption_status == "encrypted"
    end

    @tag :skip
    test "flips to decrypting then none, clears ciphertext columns" do
      # Phase B.3: vault decryption is being retired in B.4 — the plaintext
      # `path` / `folder` / `tags` / `name` columns no longer exist, so a
      # decrypt-back path that clears ciphertext is incomplete by design.
      # The DecryptVault worker is left in place but unsupported until B.4
      # removes it entirely. This test is skipped until the worker is
      # either updated or deleted.
    end
  end
end
