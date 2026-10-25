defmodule Engram.Workers.AttachmentBlobGCTest do
  @moduledoc """
  #2159: a soft delete used to remove the S3 blob in the same request. Nested
  in a folder cascade that later rolled back, that left live rows with no
  bytes. A soft delete now never touches storage; this worker reaps a
  tombstone's blob once it is past the owner's trash retention
  (`trash_retention_days`: 7 days Free, 30 paid, 30 self-host).
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import Engram.RlsCase, only: [as_prod_role: 1]

  alias Engram.{Attachments, Folders, Repo, Storage}
  alias Engram.Attachments.Attachment
  alias Engram.Storage.InMemory
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

  describe "trash retention (trash_retention_days)" do
    test "a per-user retention moves the reap point", %{user: user, vault: vault} do
      insert(:user_limit_override, user: user, key: "trash_retention_days", value: %{"v" => 2})
      kept = put_att(user, vault, "kept.png")
      gone = put_att(user, vault, "gone.png")
      :ok = Attachments.delete_attachment(user, vault, "kept.png")
      :ok = Attachments.delete_attachment(user, vault, "gone.png")
      backdate!(kept, 47)
      backdate!(gone, 49)

      assert AttachmentBlobGC.sweep() == 1
      assert blob?(kept.storage_key)
      refute blob?(gone.storage_key)
    end

    test "a paid-length retention keeps a tombstone a Free one would lose", %{
      user: user,
      vault: vault
    } do
      insert(:user_limit_override, user: user, key: "trash_retention_days", value: %{"v" => 30})
      att = put_att(user, vault, "a.png")
      :ok = Attachments.delete_attachment(user, vault, "a.png")
      backdate!(att, 8 * 24)

      assert AttachmentBlobGC.sweep() == 0
      assert blob?(att.storage_key)

      backdate!(att, 31 * 24)
      assert AttachmentBlobGC.sweep() == 1
    end

    # Self-host: enforcement off makes every key "unlimited". For retention
    # that cannot mean "keep forever" (the GC would never run), so it falls
    # back to the most generous plan's window.
    test "self-host keeps the paid window", %{user: user, vault: vault} do
      prev = Application.get_env(:engram, :limits_enforced)
      Application.put_env(:engram, :limits_enforced, false)
      on_exit(fn -> Application.put_env(:engram, :limits_enforced, prev) end)

      att = put_att(user, vault, "a.png")
      :ok = Attachments.delete_attachment(user, vault, "a.png")
      backdate!(att, 8 * 24)
      assert AttachmentBlobGC.sweep() == 0

      backdate!(att, 31 * 24)
      assert AttachmentBlobGC.sweep() == 1
    end
  end

  describe "sweep/0" do
    test "reaps a Free tombstone past 7 days, then has nothing to do", %{
      user: user,
      vault: vault
    } do
      att = put_att(user, vault, "a.png")
      :ok = Attachments.delete_attachment(user, vault, "a.png")
      backdate!(att, 7 * 24 + 1)

      assert AttachmentBlobGC.sweep() == 1
      refute blob?(att.storage_key)
      assert is_nil(reload(att).storage_key)

      assert AttachmentBlobGC.sweep() == 0
    end

    test "keeps a Free tombstone inside 7 days", %{user: user, vault: vault} do
      att = put_att(user, vault, "a.png")
      :ok = Attachments.delete_attachment(user, vault, "a.png")
      backdate!(att, 7 * 24 - 1)

      assert AttachmentBlobGC.sweep() == 0
      assert blob?(att.storage_key)
      assert reload(att).storage_key == att.storage_key
    end

    test "keeps a blob a live row still references", %{user: user, vault: vault} do
      live = put_att(user, vault, "live.png")
      tomb = put_att(user, vault, "gone.png")
      :ok = Attachments.delete_attachment(user, vault, "gone.png")
      backdate!(tomb, 8 * 24)

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
      backdate!(att, 8 * 24)

      prev = Application.get_env(:engram, :storage)
      Application.put_env(:engram, :storage, Engram.MockStorage)
      on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
      Mox.stub(Engram.MockStorage, :delete_many, fn _keys -> {:ok, 0} end)
      Mox.stub(Engram.MockStorage, :delete, fn _key -> {:error, :boom} end)

      # The key was cleared and committed before the delete; the failed
      # delete writes it back so the next run owns it again.
      assert AttachmentBlobGC.sweep() == 0
      assert reload(att).storage_key == att.storage_key

      Application.put_env(:engram, :storage, prev)
      assert blob?(att.storage_key)
      assert AttachmentBlobGC.sweep() == 1
      refute blob?(att.storage_key)
      assert is_nil(reload(att).storage_key)
    end
  end

  # A live row that gains a tombstone's key after the GC first reads its
  # candidates must keep its blob: the "no live row has this key" check has
  # to hold at the moment the key is cleared, not at the first read.
  test "a live row gaining the key mid-sweep keeps its blob", %{user: user, vault: vault} do
    tomb = put_att(user, vault, "gone.png")
    :ok = Attachments.delete_attachment(user, vault, "gone.png")
    backdate!(tomb, 8 * 24)
    live = put_att(user, vault, "live.png")
    key = tomb.storage_key

    test_pid = self()
    handler = {__MODULE__, make_ref()}
    fired = :counters.new(1, [])

    :telemetry.attach(
      handler,
      [:engram, :repo, :query],
      fn _, _, meta, _ ->
        if self() == test_pid and meta[:source] == "attachments" and
             :counters.get(fired, 1) == 0 do
          :counters.add(fired, 1, 1)

          # The race: a live row now points at the tombstone's key.
          Repo.update_all(
            from(a in Attachment, where: a.id == ^live.id),
            [set: [storage_key: key]],
            skip_tenant_check: true
          )
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert AttachmentBlobGC.sweep() == 0
    :telemetry.detach(handler)

    assert :counters.get(fired, 1) == 1
    assert blob?(key)
    assert reload(tomb).storage_key == key
  end

  defp use_mock_storage do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub_with(Engram.MockStorage, InMemory)
    prev
  end

  defp backdate_claim!(att, hours) do
    at = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    {1, _} =
      Repo.update_all(
        from(a in Attachment, where: a.id == ^att.id),
        [set: [blob_gc_claimed_at: at]],
        skip_tenant_check: true
      )
  end

  # The claim commits before the S3 call. A run that dies in between (deploy,
  # OOM, timeout) must not orphan the blob: the tombstone keeps its key, and
  # once the claim is stale the next run claims it again.
  test "a crash between claim and delete is recovered after the stale threshold", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    backdate!(att, 8 * 24)
    prev = use_mock_storage()
    Mox.stub(Engram.MockStorage, :delete_many, fn _keys -> raise "node lost" end)

    # Rescued per vault and logged; the claim is left for the stale threshold,
    # exactly as if the run had died here.
    capture_log(fn -> assert AttachmentBlobGC.sweep() == 0 end)

    claimed = reload(att)
    assert claimed.storage_key == att.storage_key
    assert claimed.blob_gc_claimed_at

    Application.put_env(:engram, :storage, prev)

    # A fresh claim belongs to a run that may still be going: left alone.
    assert AttachmentBlobGC.sweep() == 0
    assert blob?(att.storage_key)

    backdate_claim!(att, 2)
    assert AttachmentBlobGC.sweep() == 1
    refute blob?(att.storage_key)
    assert %{storage_key: nil, blob_gc_claimed_at: nil} = reload(att)
  end

  test "finalize leaves a row undeleted between claim and finalize alone", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    backdate!(att, 8 * 24)
    use_mock_storage()

    Mox.stub(Engram.MockStorage, :delete_many, fn keys ->
      # A (hypothetical) undelete brings the row back mid-run.
      Repo.update_all(
        from(a in Attachment, where: a.id == ^att.id),
        [set: [deleted_at: nil]],
        skip_tenant_check: true
      )

      InMemory.delete_many(keys)
    end)

    log = capture_log(fn -> AttachmentBlobGC.sweep() end)
    assert reload(att).storage_key == att.storage_key

    # The blob IS gone. The real undelete (`Attachments.revive_tombstones/3`)
    # takes the vault lock and skips claimed rows, so it cannot do this
    # (#2195); a raw write like this one must at least be loud and name the
    # row, so it can be restored.
    refute blob?(att.storage_key)
    assert log =~ "blob deleted but its row was not finalized"
    assert log =~ att.id
  end

  test "a delete that raises in one vault does not stop the others", %{
    user: user,
    vault: vault
  } do
    bad = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    backdate!(bad, 8 * 24)

    other = insert(:vault, user: user)
    good = put_att(user, other, "b.png")
    :ok = Attachments.delete_attachment(user, other, "b.png")
    backdate!(good, 8 * 24)
    use_mock_storage()

    Mox.stub(Engram.MockStorage, :delete_many, fn keys ->
      if Enum.any?(keys, &String.contains?(&1, vault.id)),
        do: raise("storage exploded"),
        else: InMemory.delete_many(keys)
    end)

    log = capture_log(fn -> assert AttachmentBlobGC.sweep() == 1 end)

    assert log =~ "attachment_blob_gc: blob delete raised"
    # safe_reason/1: the exception type; its message is only rendered for
    # types vetted to carry no user data.
    assert log =~ "reason=RuntimeError"
    assert is_nil(reload(good).storage_key)
    assert reload(bad).storage_key == bad.storage_key
  end

  # Only the storage call is rescued: a database error is not "nothing to
  # reap", and the job must fail so Oban records it.
  test "a database error in the claim fails the sweep", %{user: user, vault: vault} do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    backdate!(att, 8 * 24)

    Repo.query!("""
    CREATE FUNCTION test_fail_gc_claim() RETURNS trigger AS $$
    BEGIN
      IF NEW.blob_gc_claimed_at IS NOT NULL THEN RAISE EXCEPTION 'injected db failure'; END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!(
      "CREATE TRIGGER test_fail_gc_claim BEFORE UPDATE ON attachments " <>
        "FOR EACH ROW EXECUTE FUNCTION test_fail_gc_claim()"
    )

    assert_raise Postgrex.Error, ~r/injected db failure/, fn -> AttachmentBlobGC.sweep() end
  end

  test "finalize does not clear a key that changed after the claim", %{
    user: user,
    vault: vault
  } do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    backdate!(att, 8 * 24)
    use_mock_storage()
    other_key = "#{user.id}/#{vault.id}/objects/#{Ecto.UUID.generate()}"

    Mox.stub(Engram.MockStorage, :delete_many, fn keys ->
      # The row moves under the run, between its delete and its finalize.
      Repo.update_all(
        from(a in Attachment, where: a.id == ^att.id),
        [set: [storage_key: other_key]],
        skip_tenant_check: true
      )

      InMemory.delete_many(keys)
    end)

    log = capture_log(fn -> assert AttachmentBlobGC.sweep() == 0 end)

    assert reload(att).storage_key == other_key
    assert log =~ "blob deleted but its row was not finalized"
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
      backdate!(att, 8 * 24)

      assert {:returned, {:error, :tenancy_unsafe}} =
               as_prod_role(fn -> perform_job(AttachmentBlobGC, %{}) end)

      assert blob?(att.storage_key)
      assert reload(att).storage_key == att.storage_key
    end
  end

  test "perform/1 sweeps", %{user: user, vault: vault} do
    att = put_att(user, vault, "a.png")
    :ok = Attachments.delete_attachment(user, vault, "a.png")
    backdate!(att, 8 * 24)

    assert :ok = perform_job(AttachmentBlobGC, %{})
    refute blob?(att.storage_key)
  end
end
