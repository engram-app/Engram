defmodule Engram.Workers.BackfillContentHashHmacTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Engram.Fixtures

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.BackfillContentHashHmac

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    insert(:user_override, user: user, overrides: %{"max_vaults" => -1})
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "BackfillTest"})

    %{user: user, vault: vault}
  end

  describe "perform/1 — notes scope" do
    test "rehashes a note whose content_hash is legacy MD5", %{user: user, vault: vault} do
      content = "# Backfill me\nbody bytes"
      legacy_md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

      note = insert_note!(user, vault, %{"content" => content, "content_hash" => legacy_md5})

      assert :ok =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })

      {:ok, reloaded} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
      {:ok, content_key} = Crypto.dek_content_hash_key(user)
      expected = Crypto.hmac_content_hash(content_key, content)

      assert reloaded.content_hash == expected
      assert String.length(reloaded.content_hash) == 64
      refute reloaded.content_hash == legacy_md5
    end

    test "skips notes that already have HMAC-format content_hash", %{user: user, vault: vault} do
      content = "already hashed"
      {:ok, content_key} = Crypto.dek_content_hash_key(user)
      hmac_hash = Crypto.hmac_content_hash(content_key, content)

      note = insert_note!(user, vault, %{"content" => content, "content_hash" => hmac_hash})

      assert :ok =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })

      {:ok, reloaded} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
      assert reloaded.content_hash == hmac_hash
    end

    test "rewrites embed_hash in lock-step when row was already embedded",
         %{user: user, vault: vault} do
      content = "indexed body"
      legacy_md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

      note =
        insert_note!(user, vault, %{"content" => content, "content_hash" => legacy_md5})

      stamp_embed_hash!(user.id, note.id, legacy_md5)

      assert :ok =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })

      {:ok, reloaded} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
      assert reloaded.embed_hash == reloaded.content_hash
    end

    test "leaves embed_hash alone when content has unembedded changes",
         %{user: user, vault: vault} do
      content = "modified after embed"
      legacy_md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
      stale_embed = "stale_md5_from_prior_content"

      note =
        insert_note!(user, vault, %{"content" => content, "content_hash" => legacy_md5})

      stamp_embed_hash!(user.id, note.id, stale_embed)

      assert :ok =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })

      {:ok, reloaded} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
      refute reloaded.content_hash == legacy_md5
      assert reloaded.embed_hash == stale_embed
    end

    defp stamp_embed_hash!(user_id, note_id, hash) do
      import Ecto.Query

      {:ok, _} =
        Repo.with_tenant(user_id, fn ->
          from(n in Note, where: n.id == ^note_id)
          |> Repo.update_all(set: [embed_hash: hash])
        end)
    end

    test "no-op when no legacy MD5 rows remain", %{user: user, vault: vault} do
      assert :ok =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })
    end
  end

  # ---------------------------------------------------------------------------
  # T3.7 — RotationGate
  # ---------------------------------------------------------------------------

  describe "perform/1 — T3.7 rotation gate" do
    test "snoozes for 60 seconds when user's DEK rotation is in progress", %{
      user: user,
      vault: vault
    } do
      # Set lock directly — do NOT use RotationLock.acquire/2 (advisory lock
      # does not survive across a Sandbox checkout in non-async tests).
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      assert {:snooze, 60} =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })
    end

    test "discards job when user does not exist", %{vault: vault} do
      assert {:discard, :user_deleted} =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => 0,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })
    end
  end
end
