defmodule Engram.Workers.ReconcileAttachmentBlobsTest do
  @moduledoc """
  #2159: a live row whose blob sits behind delete markers in a versioned
  bucket is restored by copying its newest data version back. The test
  storage (`InMemory`) keeps versions like S3 does.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import Engram.RlsCase, only: [as_prod_role: 1]

  alias Engram.Accounts.User
  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Storage.InMemory
  alias Engram.Vaults.Vault
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
    Mox.stub(Engram.MockStorage, :list_versions, fn _, _ -> {:error, :unsupported} end)

    assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault))
  end

  test "pages the listing; a key split across pages is still restored", %{
    user: user,
    vault: vault
  } do
    prev = Application.get_env(:engram, :reconcile_versions_page)
    Application.put_env(:engram, :reconcile_versions_page, 1)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:engram, :reconcile_versions_page, prev),
        else: Application.delete_env(:engram, :reconcile_versions_page)
    end)

    atts = for p <- ["a.png", "b.png"], do: put_att(user, vault, p, "bytes of " <> p)
    # Each key: data version + two markers, so every key spans three pages.
    for att <- atts, _ <- 1..2, do: :ok = Storage.adapter().delete(att.storage_key)

    log =
      capture_log(fn -> assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault)) end)

    refute log =~ "attachment blob unrecoverable"

    for p <- ["a.png", "b.png"] do
      assert {:ok, %{content: content}} = Attachments.get_attachment(user, vault, p)
      assert content == "bytes of " <> p
    end
  end

  test "makes no copy while the account is being deleted", %{user: user, vault: vault} do
    att = put_att(user, vault, "a.png", "bytes")

    # hard_delete's window: soft-deleted, prefix wiped, rows not yet gone.
    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        [set: [deleted_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

    {:ok, _} = Storage.adapter().delete_prefix("#{user.id}/")

    assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault))
    refute Storage.adapter().exists?(att.storage_key)
  end

  test "makes no copy for a vault being purged", %{user: user, vault: vault} do
    att = put_att(user, vault, "a.png", "bytes")
    :ok = Storage.adapter().delete(att.storage_key)

    {1, _} =
      Repo.update_all(
        from(v in Vault, where: v.id == ^vault.id),
        [set: [purge_started_at: DateTime.utc_now(:second)]],
        skip_tenant_check: true
      )

    assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault))
    refute Storage.adapter().exists?(att.storage_key)
  end

  test "an upload landing after the listing is not called unrecoverable", %{
    user: user,
    vault: vault
  } do
    put_att(user, vault, "a.png", "bytes")

    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub_with(Engram.MockStorage, InMemory)

    Mox.stub(Engram.MockStorage, :list_versions, fn prefix, opts ->
      listed = InMemory.list_versions(prefix, opts)
      # Commits between the listing and the decision.
      put_att(user, vault, "late.png", "late bytes")
      listed
    end)

    log =
      capture_log(fn -> assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault)) end)

    refute log =~ "attachment blob unrecoverable"
  end

  defp use_mock_storage do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub_with(Engram.MockStorage, InMemory)
  end

  test "a key change (client heal) between listing and copy makes no copy", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png", "bytes")
    :ok = Storage.adapter().delete(att.storage_key)
    use_mock_storage()

    old_key = att.storage_key

    # The client re-pushes its copy AFTER the reconciler read the row and
    # right before its copy: the row moves to a fresh key, the old one stays
    # gone.
    Mox.stub(Engram.MockStorage, :get_range, fn
      ^old_key, _, _ ->
        healed = "#{user.id}/#{vault.id}/objects/#{Ecto.UUID.generate()}"
        :ok = InMemory.put(healed, "sealed")

        {1, _} =
          Repo.update_all(
            from(a in Attachment, where: a.id == ^att.id),
            [set: [storage_key: healed]],
            skip_tenant_check: true
          )

        {:error, :not_found}

      key, offset, len ->
        InMemory.get_range(key, offset, len)
    end)

    assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault))
    refute InMemory.exists?(old_key)
  end

  test "an account deletion that starts mid-page stops the remaining copies", %{
    user: user,
    vault: vault
  } do
    atts = for p <- ["a.png", "b.png"], do: put_att(user, vault, p, "bytes of " <> p)
    for att <- atts, do: :ok = Storage.adapter().delete(att.storage_key)
    use_mock_storage()
    test_pid = self()

    Mox.stub(Engram.MockStorage, :restore_version, fn key, vid ->
      send(test_pid, {:restored, key})
      :ok = InMemory.restore_version(key, vid)

      # Account deletion begins after the first copy.
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        [set: [deleted_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      :ok
    end)

    assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault))
    assert_received {:restored, _}
    refute_received {:restored, _}
  end

  test "a transient storage error is not reported as unrecoverable", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png", "bytes")
    lost = "#{user.id}/#{vault.id}/objects/#{Ecto.UUID.generate()}"

    {1, _} =
      Repo.update_all(from(a in Attachment, where: a.id == ^att.id), [set: [storage_key: lost]],
        skip_tenant_check: true
      )

    use_mock_storage()
    Mox.stub(Engram.MockStorage, :exists?, fn _ -> false end)
    Mox.stub(Engram.MockStorage, :get_range, fn _, _, _ -> {:error, :timeout} end)

    log =
      capture_log(fn -> assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault)) end)

    refute log =~ "attachment blob unrecoverable"
    # Not silent: a persistent error (an IAM change) must be visible.
    assert log =~ "attachment blob probe failed, retrying on the next run"
    assert log =~ "vault_id=#{vault.id}"
    refute log =~ lost
  end

  # A 0-byte object answers a ranged GET with 416 InvalidRange: it exists.
  test "a 416 on the probe counts as present: no copy, no warning", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png", "bytes")
    :ok = Storage.adapter().delete(att.storage_key)
    use_mock_storage()
    test_pid = self()

    Mox.stub(Engram.MockStorage, :get_range, fn _, _, _ ->
      {:error, {:http_error, 416, %{body: "InvalidRange"}}}
    end)

    Mox.stub(Engram.MockStorage, :restore_version, fn key, _ ->
      send(test_pid, {:restored, key})
      :ok
    end)

    log =
      capture_log(fn -> assert :ok = perform_job(ReconcileAttachmentBlobs, args(user, vault)) end)

    refute_received {:restored, _}
    refute log =~ "probe failed"
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
