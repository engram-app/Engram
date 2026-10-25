defmodule Engram.Attachments.ReviveTombstonesTest do
  @moduledoc """
  #2195: a tombstone revived after blob GC claims its key, but before the S3
  delete runs, came back as a live row with no bytes. `revive_tombstones/3`
  takes the vault lock the GC claim takes and refuses any row that holds a
  fresh claim (or no key), so a restore either brings the row back with its
  blob or reports it unrestored. It never leaves a live row without a blob.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Engram.{Attachments, Repo, Storage}
  alias Engram.Attachments.Attachment
  alias Engram.Storage.InMemory
  alias Engram.Workers.AttachmentBlobGC

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp put_att(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes of " <> path)
      })

    reload(att)
  end

  defp reload(att), do: Repo.get!(Attachment, att.id, skip_tenant_check: true)

  defp blob?(key), do: match?({:ok, _}, Storage.adapter().get(key))

  # Far past every plan's trash retention, so the GC treats it as reapable.
  defp backdate!(att) do
    at = DateTime.add(DateTime.utc_now(:second), -400 * 86_400, :second)

    {1, _} =
      Repo.update_all(from(a in Attachment, where: a.id == ^att.id), [set: [deleted_at: at]],
        skip_tenant_check: true
      )
  end

  defp use_mock_storage do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub_with(Engram.MockStorage, InMemory)
  end

  test "revives an unclaimed tombstone with its blob", %{user: user, vault: vault} do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    before = reload(att)

    assert {:ok, %{restored: [id], unrestored: []}} =
             Attachments.revive_tombstones(user, vault, [att.id])

    assert id == att.id
    revived = reload(att)
    assert is_nil(revived.deleted_at)
    assert revived.seq > before.seq
    assert blob?(revived.storage_key)
  end

  # The race itself: the GC has claimed the key and is inside the S3 delete
  # when the restore arrives. Before #2195 the restore cleared `deleted_at`,
  # the delete then removed the bytes, and a live row pointed at nothing.
  test "a restore between the GC claim and the S3 delete is refused", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    backdate!(att)
    use_mock_storage()
    test_pid = self()

    Mox.stub(Engram.MockStorage, :delete_many, fn keys ->
      send(test_pid, {:revive, Attachments.revive_tombstones(user, vault, [att.id])})
      InMemory.delete_many(keys)
    end)

    capture_log(fn -> assert AttachmentBlobGC.sweep() == 1 end)

    assert_received {:revive, {:ok, %{restored: [], unrestored: [unrestored]}}}
    assert unrestored == att.id

    after_gc = reload(att)
    refute blob?(att.storage_key)
    assert after_gc.deleted_at, "a live row whose blob the GC just deleted"
    assert is_nil(after_gc.storage_key)
  end

  test "a restore before the GC claims keeps the blob", %{user: user, vault: vault} do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    backdate!(att)

    assert {:ok, %{restored: [_]}} = Attachments.revive_tombstones(user, vault, [att.id])
    assert AttachmentBlobGC.sweep() == 0
    assert blob?(att.storage_key)
  end

  test "a reaped tombstone (no key) is refused", %{user: user, vault: vault} do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    backdate!(att)
    assert AttachmentBlobGC.sweep() == 1

    assert {:ok, %{restored: [], unrestored: [_]}} =
             Attachments.revive_tombstones(user, vault, [att.id])

    assert reload(att).deleted_at
  end

  defp stamp_claim!(att, at) do
    {1, _} =
      Repo.update_all(
        from(a in Attachment, where: a.id == ^att.id),
        [set: [blob_gc_claimed_at: at]],
        skip_tenant_check: true
      )
  end

  # A stale claim only says the GC run died, not whether it died before or
  # after its S3 delete. Reviving it could leave a live row with no bytes, so
  # every claimed row is refused and left for the next GC run to finalize.
  test "a stale claim whose blob the dead run already deleted is refused", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    stamp_claim!(att, DateTime.add(DateTime.utc_now(), -2 * 3600, :second))
    :ok = Storage.adapter().delete(att.storage_key)

    assert {:ok, %{restored: [], unrestored: [_]}} =
             Attachments.revive_tombstones(user, vault, [att.id])

    assert reload(att).deleted_at, "a live row whose blob is gone"
  end

  test "a stale claim is refused even while its blob is still there", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    stamp_claim!(att, DateTime.add(DateTime.utc_now(), -2 * 3600, :second))

    assert {:ok, %{restored: [], unrestored: [_]}} =
             Attachments.revive_tombstones(user, vault, [att.id])

    assert reload(att).deleted_at
  end

  test "a path a live row now holds is refused, not a unique-index crash", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    _new = put_att(user, vault, "a.png")

    assert {:ok, %{restored: [], unrestored: [_]}} =
             Attachments.revive_tombstones(user, vault, [att.id])

    assert reload(att).deleted_at
  end
end
