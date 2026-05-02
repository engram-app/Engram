defmodule Engram.Workers.BackfillByteaToS3Test do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Repo
  alias Engram.Workers.BackfillByteaToS3

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

    stub_with(Engram.MockStorage, Engram.Storage.InMemory)
    :ok
  end

  defp insert_legacy_attachment(user, vault, path, plaintext) do
    Repo.with_tenant(user.id, fn ->
      %Attachment{}
      |> Attachment.changeset(%{
        path: path,
        content: plaintext,
        content_hash: :crypto.hash(:md5, plaintext) |> Base.encode16(case: :lower),
        mime_type: "application/octet-stream",
        size_bytes: byte_size(plaintext),
        user_id: user.id,
        vault_id: vault.id,
        storage_key: Engram.Storage.key(user.id, vault.id, path),
        encryption_version: 0
      })
      |> Repo.insert()
    end)
    |> case do
      {:ok, {:ok, att}} -> att
      other -> raise "factory insert failed: #{inspect(other)}"
    end
  end

  test "backfills one legacy BYTEA row to encrypted S3 + flips version" do
    user = insert(:user) |> Repo.reload!()
    vault = insert(:vault, user: user)
    att = insert_legacy_attachment(user, vault, "doc.pdf", "PDF-bytes-here")

    assert :ok =
             perform_job(BackfillByteaToS3, %{
               user_id: user.id,
               vault_id: vault.id,
               cursor: 0
             })

    reloaded = Repo.get!(Attachment, att.id, skip_tenant_check: true)
    assert reloaded.encryption_version == 1
    assert is_binary(reloaded.content_nonce)

    {:ok, ciphertext} = Engram.Storage.InMemory.get(reloaded.storage_key)
    refute ciphertext == "PDF-bytes-here"

    {:ok, user} = Crypto.ensure_user_dek(Repo.reload!(user))
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, plaintext} = Envelope.decrypt(ciphertext, reloaded.content_nonce, dek)
    assert plaintext == "PDF-bytes-here"
  end

  test "is idempotent — re-running on a v=1 row is a no-op" do
    user = insert(:user) |> Repo.reload!()
    vault = insert(:vault, user: user)
    _att = insert_legacy_attachment(user, vault, "doc.pdf", "PDF-bytes")

    assert :ok =
             perform_job(BackfillByteaToS3, %{user_id: user.id, vault_id: vault.id, cursor: 0})

    # Mox.expect(0) — second run must NOT call put again
    expect(Engram.MockStorage, :put, 0, fn _, _, _ -> :ok end)
    stub_with(Engram.MockStorage, Engram.Storage.InMemory)

    assert :ok =
             perform_job(BackfillByteaToS3, %{user_id: user.id, vault_id: vault.id, cursor: 0})
  end

  test "S3 put failure leaves row unchanged" do
    user = insert(:user) |> Repo.reload!()
    vault = insert(:vault, user: user)
    att = insert_legacy_attachment(user, vault, "fail.pdf", "x")

    expect(Engram.MockStorage, :put, fn _, _, _ -> {:error, :timeout} end)

    assert {:error, _} =
             perform_job(BackfillByteaToS3, %{user_id: user.id, vault_id: vault.id, cursor: 0})

    reloaded = Repo.get!(Attachment, att.id, skip_tenant_check: true)
    assert reloaded.encryption_version == 0
    assert is_nil(reloaded.content_nonce)
  end
end
