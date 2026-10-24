defmodule Engram.Workers.ReconcileAttachmentBlobsTest do
  @moduledoc """
  #2159: a live row whose blob sits behind delete markers in a versioned
  bucket is restored by copying its newest data version back. The test
  storage (`Engram.Storage.InMemory`) keeps versions like S3 does.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import Engram.RlsCase, only: [as_prod_role: 1]

  alias Engram.{Attachments, Repo, Storage}
  alias Engram.Attachments.Attachment
  alias Engram.Workers.ReconcileAttachmentBlobs

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp put_att(user, vault, path, bytes) do
    {:ok, _} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64(bytes)
      })

    {:ok, att} = Attachments.get_attachment(user, vault, path)
    Repo.get!(Attachment, att.id, skip_tenant_check: true)
  end

  defp reload(att), do: Repo.get!(Attachment, att.id, skip_tenant_check: true)
  defp args(user, vault), do: %{"user_id" => user.id, "vault_id" => vault.id}

  test "restores a blob behind one delete marker and bumps the row's seq", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png", "original bytes")
    :ok = Storage.adapter().delete(att.storage_key)

    assert {:error, {:storage, :blob_missing}} = Attachments.get_attachment(user, vault, "a.png")

    assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault))

    assert {:ok, %{content: "original bytes"}} =
             Attachments.get_attachment(user, vault, "a.png")

    assert reload(att).seq > att.seq
  end

  test "restores the newest DATA version from under two stacked markers", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png", "original bytes")
    :ok = Storage.adapter().delete(att.storage_key)
    :ok = Storage.adapter().delete(att.storage_key)

    assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault))

    assert {:ok, %{content: "original bytes"}} =
             Attachments.get_attachment(user, vault, "a.png")
  end

  test "a tombstoned row with a markered key stays deleted, its blob stays gone", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "gone.png", "deleted bytes")
    :ok = Attachments.delete_attachment(user, vault, "gone.png")
    :ok = Storage.adapter().delete(att.storage_key)

    assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault))

    assert reload(att).deleted_at
    refute Storage.adapter().exists?(att.storage_key)
  end

  test "a healthy row is left alone", %{user: user, vault: vault} do
    att = put_att(user, vault, "a.png", "bytes")
    assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault))
    assert reload(att).seq == att.seq
  end

  # engram-infra alert rules match this literal line; renaming it silences them.
  test "logs `attachment blob unrecoverable` when no data version is left", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png", "bytes")
    lost = "#{user.id}/#{vault.id}/objects/#{Ecto.UUID.generate()}"

    {1, _} =
      Repo.update_all(from(a in Attachment, where: a.id == ^att.id), [set: [storage_key: lost]],
        skip_tenant_check: true
      )

    log =
      capture_log(fn -> assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault)) end)

    assert log =~ "attachment blob unrecoverable"
    assert reload(att).seq == att.seq
  end

  test "an unversioned backend makes it a no-op", %{user: user, vault: vault} do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub(Engram.MockStorage, :list_versions, fn _ -> {:error, :unsupported} end)

    assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault))
  end

  test "a read of a missing blob enqueues a reconcile for the vault", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png", "bytes")
    :ok = Storage.adapter().delete(att.storage_key)

    {:error, {:storage, :blob_missing}} = Attachments.get_attachment(user, vault, "a.png")

    assert_enqueued(worker: ReconcileAttachmentBlobs, args: args(user, vault))
  end

  describe "the daily fan-out" do
    test "enqueues one job per vault holding live attachments", %{user: user, vault: vault} do
      put_att(user, vault, "a.png", "bytes")
      empty = insert(:vault, user: user)

      assert :ok = perform_job(ReconcileAttachmentBlobs, %{})

      assert_enqueued(worker: ReconcileAttachmentBlobs, args: args(user, vault))
      refute_enqueued(worker: ReconcileAttachmentBlobs, args: args(user, empty))
    end

    test "control: the dropped role sees zero attachment rows", %{user: user, vault: vault} do
      put_att(user, vault, "a.png", "bytes")

      assert {:returned, []} =
               as_prod_role(fn -> Repo.all(Attachment, skip_tenant_check: true) end)
    end

    test "refuses under enforced RLS with no maintenance pool", %{user: user, vault: vault} do
      put_att(user, vault, "a.png", "bytes")

      assert {:returned, {:error, :tenancy_unsafe}} =
               as_prod_role(fn -> perform_job(ReconcileAttachmentBlobs, %{}) end)
    end
  end
end
