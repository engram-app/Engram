defmodule Engram.Crypto.EncryptVaultTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Crypto
  alias Engram.Vaults.Vault
  alias Engram.Workers.EncryptVault
  alias Engram.Repo

  setup do
    user = insert(:user, encryption_toggle_cooldown_days: 7)
    vault = insert(:vault, user: user, encrypted: false, encryption_status: "none")
    %{user: user, vault: vault}
  end

  defp set_cooldown(user, days) do
    user |> Ecto.Changeset.change(%{encryption_toggle_cooldown_days: days}) |> Repo.update!()
  end

  defp set_last_toggle(vault, ago_days) do
    ts = DateTime.utc_now() |> DateTime.add(-ago_days, :day)
    {:ok, v} = vault |> Ecto.Changeset.change(%{last_toggle_at: ts}) |> Repo.update()
    v
  end

  describe "encrypt_vault/2" do
    test "flips vault to encrypting and enqueues EncryptVault worker", %{user: user, vault: vault} do
      assert {:ok, updated} = Crypto.encrypt_vault(vault, user)
      assert updated.encrypted == true
      assert updated.encryption_status == "encrypting"
      assert updated.last_toggle_at != nil

      assert_enqueued(
        worker: EncryptVault,
        args: %{"vault_id" => vault.id, "user_id" => user.id, "cursor" => 0}
      )
    end

    test "returns :bad_status when already encrypted", %{user: user, vault: vault} do
      {:ok, vault} = Vault.update_status(vault, "encrypted")
      assert {:error, :bad_status} = Crypto.encrypt_vault(vault, user)
    end

    test "returns :bad_status when currently encrypting", %{user: user, vault: vault} do
      {:ok, vault} = Vault.update_status(vault, "encrypting")
      assert {:error, :bad_status} = Crypto.encrypt_vault(vault, user)
    end

    test "returns :cooldown when last_toggle_at within configured cooldown", %{
      user: user,
      vault: vault
    } do
      vault = set_last_toggle(vault, 3)
      assert {:error, :cooldown} = Crypto.encrypt_vault(vault, user)
    end

    test "succeeds when last_toggle_at older than configured cooldown", %{
      user: user,
      vault: vault
    } do
      vault = set_last_toggle(vault, 8)
      assert {:ok, _} = Crypto.encrypt_vault(vault, user)
    end

    test "skips cooldown when user.encryption_toggle_cooldown_days is NULL", %{
      user: user,
      vault: vault
    } do
      user = set_cooldown(user, nil)
      vault = set_last_toggle(vault, 1)
      assert {:ok, _} = Crypto.encrypt_vault(vault, user)
    end

    test "skips cooldown when user.encryption_toggle_cooldown_days is 0", %{
      user: user,
      vault: vault
    } do
      user = set_cooldown(user, 0)
      vault = set_last_toggle(vault, 0)
      assert {:ok, _} = Crypto.encrypt_vault(vault, user)
    end

    test "honors a custom cooldown of 30 days", %{user: user, vault: vault} do
      user = set_cooldown(user, 30)
      vault = set_last_toggle(vault, 10)
      assert {:error, :cooldown} = Crypto.encrypt_vault(vault, user)
    end
  end

  describe "perform/1 multi-batch re-enqueue" do
    test "self-enqueues next batch when full @batch_size hit", %{user: user, vault: vault} do
      # Regression: Oban's `unique` config was previously `[states:
      # [:available, :scheduled, :executing]]`. The worker re-enqueues from
      # inside its own `executing` perform/1, so Oban flagged the next-batch
      # insert as a duplicate and silently dropped it, stranding the vault in
      # `encrypting`. We don't want to actually run 100 notes through the real
      # pipeline here — instead we drive the unique-constraint path directly:
      # simulate the in-flight executing job, then prove a sibling next-batch
      # insert lands cleanly.
      {:ok, executing_job} =
        EncryptVault.new(%{vault_id: vault.id, user_id: user.id, cursor: 0})
        |> Oban.insert()

      {:ok, _} =
        from(j in Oban.Job, where: j.id == ^executing_job.id)
        |> Repo.update_all(set: [state: "executing"])
        |> then(fn {n, _} -> {:ok, n} end)

      {:ok, next} =
        EncryptVault.new(%{vault_id: vault.id, user_id: user.id, cursor: 100})
        |> Oban.insert()

      refute next.conflict?,
             "next-batch insert must not be flagged as a unique conflict against the currently-executing job — that's the bug we're guarding against"

      # `next` comes back from `Oban.insert/1` as a fresh struct — args still
      # carry atom keys at this point (only post-load reads stringify them).
      assert (next.args["cursor"] || next.args[:cursor]) == 100
    end
  end

  describe "perform/1 transaction boundary" do
    import Mox
    setup :verify_on_exit!

    test "calls the embedder OUTSIDE any DB transaction", %{user: user, vault: vault} do
      # Regression guard for the 2026-04-30 incident: the worker used to wrap
      # the whole batch in `Repo.with_tenant/2` (a transaction), holding a
      # Postgres connection across the slow Voyage AI HTTP call and tripping
      # the 15s checkout timeout on real-size vaults.
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
      end)

      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      # Insert the note while the vault is still in "none" state so the row
      # carries plaintext content — same shape the encrypt worker sees in
      # production: notes pre-existed as plaintext, then the user toggled
      # encryption on.
      {:ok, _note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "tx-boundary/note.md",
          "content" => "# Header\n\nSome body.",
          "mtime" => 1_000.0
        })

      vault =
        vault
        |> Ecto.Changeset.change(%{encrypted: true, encryption_status: "encrypting"})
        |> Repo.update!()

      test_pid = self()

      # Sandbox wraps every test in an outer savepoint, so `Repo.in_transaction?/0`
      # is always true here. Use the worker's own tenant guard instead — it's
      # set by `Repo.with_tenant/2` and cleared in its `after` clause, so it
      # tracks "inside a worker-controlled tx" exactly.
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        send(test_pid, {:tenant_during_embed, Process.get(:engram_tenant)})
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      assert :ok =
               EncryptVault.perform(%Oban.Job{
                 args: %{"vault_id" => vault.id, "user_id" => user.id, "cursor" => 0}
               })

      assert_received {:tenant_during_embed, nil},
                      "embed_texts must be called outside the worker's `with_tenant` transaction so the Postgres connection isn't held during the slow HTTP call"
    end
  end

  describe "perform/1 retry idempotency" do
    test "skips notes whose ciphertext is already populated", %{user: user, vault: vault} do
      # Regression: the worker commits per-note encryption before issuing the
      # next-batch enqueue. If that enqueue fails (transient DB error, unique
      # conflict, network blip), perform/1 returns an error and Oban retries
      # the SAME job with the SAME cursor. Without the load-batch filter, the
      # retry would reload the already-encrypted notes — content_ciphertext
      # set, plaintext nulled — and `Indexing.prepare_index` would parse
      # `note.content || ""` as empty, then `encrypt_postgres` would overwrite
      # the existing ciphertext with ciphertext-of-empty. Plaintext gone.
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, already_encrypted_note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "retry/already.md",
          "content" => "# Already done",
          "mtime" => 1_000.0
        })

      already_encrypted_note
      |> Ecto.Changeset.change(%{
        content: nil,
        content_ciphertext: <<1, 2, 3>>,
        content_nonce: <<4, 5, 6>>
      })
      |> Repo.update!()

      vault
      |> Ecto.Changeset.change(%{encrypted: true, encryption_status: "encrypting"})
      |> Repo.update!()

      # The retry path: cursor=0, vault is in `encrypting`, the only matching
      # row is one whose ciphertext is already populated. The load query must
      # filter it out and the worker must finalize the empty batch instead of
      # round-tripping it through the encryption pipeline.
      assert :ok =
               EncryptVault.perform(%Oban.Job{
                 args: %{"vault_id" => vault.id, "user_id" => user.id, "cursor" => 0}
               })

      {:ok, reloaded} =
        Repo.with_tenant(user.id, fn ->
          Repo.get!(Engram.Notes.Note, already_encrypted_note.id)
        end)

      assert reloaded.content_ciphertext == <<1, 2, 3>>,
             "an already-encrypted note must not be re-encrypted on retry"

      assert reloaded.content_nonce == <<4, 5, 6>>,
             "the nonce must not be regenerated on retry — that would invalidate the existing ciphertext"
    end
  end
end
