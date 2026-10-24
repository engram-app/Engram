defmodule Engram.Workers.AttachmentBlobGCTest do
  @moduledoc """
  #2159: a soft delete used to remove the S3 blob in the same request. Nested
  in a folder cascade that later rolled back, that left live rows with no
  bytes. A soft delete now never touches storage; this worker reaps a
  tombstone's blob once it is past the grace window.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.RlsCase, only: [as_prod_role: 1]

  alias Engram.{Attachments, Folders, Repo, Storage}
  alias Engram.Attachments.Attachment
  alias Engram.Workers.AttachmentBlobGC

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp put_att(user, vault, path) do
    {:ok, _} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes of " <> path)
      })

    live_row(vault, path_hmac(user, path))
  end

  defp path_hmac(user, path) do
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    Engram.Crypto.hmac_field(filter_key, path)
  end

  defp live_row(vault, hmac) do
    Repo.one!(
      from(a in Attachment,
        where: a.vault_id == ^vault.id and a.path_hmac == ^hmac and is_nil(a.deleted_at)
      ),
      skip_tenant_check: true
    )
  end

  defp reload(att), do: Repo.get!(Attachment, att.id, skip_tenant_check: true)

  defp backdate!(att, hours) do
    at = DateTime.add(DateTime.utc_now(:second), -hours * 3600, :second)

    {1, _} =
      Repo.update_all(from(a in Attachment, where: a.id == ^att.id), [set: [deleted_at: at]],
        skip_tenant_check: true
      )
  end

  defp blob?(key), do: match?({:ok, _}, Storage.adapter().get(key))

  describe "a soft delete keeps the blob" do
    test "delete_attachment/3", %{user: user, vault: vault} do
      att = put_att(user, vault, "a.png")
      :ok = Attachments.delete_attachment(user, vault, "a.png")

      assert reload(att).deleted_at
      assert blob?(att.storage_key)
    end

    test "batch_delete/3", %{user: user, vault: vault} do
      att = put_att(user, vault, "a.png")
      {:ok, %{deleted: 1}} = Attachments.batch_delete(user, vault, ["a.png"])

      assert blob?(att.storage_key)
    end

    test "a recursive folder delete that rolls back keeps every blob", %{
      user: user,
      vault: vault
    } do
      atts = for p <- ["Docs/a.png", "Docs/b.png"], do: put_att(user, vault, p)

      # A rollback after the attachment leg, from anywhere above it (prod: the
      # 15 s checkout kill). Before #2159 the blobs were already gone here.
      assert_raise RuntimeError, "rollback", fn ->
        Repo.transaction(fn ->
          {:ok, %{attachments: 2}} = Folders.delete(user, vault, "Docs", recursive: true)
          raise "rollback"
        end)
      end

      for att <- atts do
        assert is_nil(reload(att).deleted_at)
        assert blob?(att.storage_key)
      end
    end
  end

  describe "sweep/0" do
    test "reaps a tombstone past the grace window, then has nothing to do", %{
      user: user,
      vault: vault
    } do
      att = put_att(user, vault, "a.png")
      :ok = Attachments.delete_attachment(user, vault, "a.png")
      backdate!(att, 25)

      assert AttachmentBlobGC.sweep() == 1
      refute blob?(att.storage_key)
      assert is_nil(reload(att).storage_key)

      assert AttachmentBlobGC.sweep() == 0
    end

    test "keeps a tombstone inside the grace window", %{user: user, vault: vault} do
      att = put_att(user, vault, "a.png")
      :ok = Attachments.delete_attachment(user, vault, "a.png")
      backdate!(att, 23)

      assert AttachmentBlobGC.sweep() == 0
      assert blob?(att.storage_key)
      assert reload(att).storage_key == att.storage_key
    end

    test "keeps a blob a live row still references", %{user: user, vault: vault} do
      live = put_att(user, vault, "live.png")
      tomb = put_att(user, vault, "gone.png")
      :ok = Attachments.delete_attachment(user, vault, "gone.png")
      backdate!(tomb, 48)

      {1, _} =
        Repo.update_all(
          from(a in Attachment, where: a.id == ^tomb.id),
          [set: [storage_key: live.storage_key]],
          skip_tenant_check: true
        )

      assert AttachmentBlobGC.sweep() == 0
      assert blob?(live.storage_key)
    end

    test "a key whose delete fails is kept for the next run", %{user: user, vault: vault} do
      att = put_att(user, vault, "a.png")
      :ok = Attachments.delete_attachment(user, vault, "a.png")
      backdate!(att, 48)

      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      Mox.stub(Engram.MockStorage, :delete_many, fn _keys -> {:ok, 0} end)
      Mox.stub(Engram.MockStorage, :delete, fn _key -> {:error, :boom} end)

      assert AttachmentBlobGC.sweep() == 0
      assert reload(att).storage_key == att.storage_key
    end
  end

  describe "under enforced RLS with no maintenance pool" do
    # Control: proves the dropped role really is blind. Without it the refusal
    # test below could pass because the role drop never engaged.
    test "control: the dropped role sees zero attachment rows", %{user: user, vault: vault} do
      put_att(user, vault, "a.png")

      assert {:returned, []} =
               as_prod_role(fn -> Repo.all(Attachment, skip_tenant_check: true) end)
    end

    test "refuses and deletes nothing", %{user: user, vault: vault} do
      att = put_att(user, vault, "a.png")
      :ok = Attachments.delete_attachment(user, vault, "a.png")
      backdate!(att, 48)

      assert {:returned, {:error, :tenancy_unsafe}} =
               as_prod_role(fn -> perform_job(AttachmentBlobGC, %{}) end)

      assert blob?(att.storage_key)
      assert reload(att).storage_key == att.storage_key
    end
  end

  test "perform/1 sweeps", %{user: user, vault: vault} do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    backdate!(att, 48)

    assert :ok = perform_job(AttachmentBlobGC, %{})
    refute blob?(att.storage_key)
  end
end
