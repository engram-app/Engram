defmodule Engram.Workers.AttachmentUploadExpiryTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Mox

  alias Engram.Attachments.Upload
  alias Engram.Attachments.Uploads
  alias Engram.Crypto
  alias Engram.Storage.InMemory
  alias Engram.Workers.AttachmentUploadExpiry

  setup :verify_on_exit!

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    stub_with(Engram.MockStorage, InMemory)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp start!(user, vault, path) do
    {:ok, %Upload{} = up} = Uploads.start(user, vault, %{path: path, size_bytes: 10, mtime: 1.0})
    up
  end

  defp age!(up, hours) do
    at = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    {1, _} =
      from(u in Upload, where: u.id == ^up.id)
      |> Repo.update_all([set: [updated_at: at]], skip_tenant_check: true)
  end

  defp exists?(up),
    do: Repo.exists?(from(u in Upload, where: u.id == ^up.id), skip_tenant_check: true)

  test "drops a session idle 25h and aborts its multipart upload; keeps one idle 23h", ctx do
    stale = start!(ctx.user, ctx.vault, "stale.png")
    fresh = start!(ctx.user, ctx.vault, "fresh.png")
    age!(stale, 25)
    age!(fresh, 23)

    expect(Engram.MockStorage, :abort_multipart_upload, fn key, id ->
      assert {key, id} == {stale.storage_key, stale.s3_upload_id}
      :ok
    end)

    assert :ok = perform_job(AttachmentUploadExpiry, %{})
    refute exists?(stale)
    assert exists?(fresh)
  end

  test "an assembled stale session has its object deleted, not aborted", ctx do
    up = start!(ctx.user, ctx.vault, "done.png")
    age!(up, 25)

    from(u in Upload, where: u.id == ^up.id)
    |> Repo.update_all([set: [assembled_at: DateTime.utc_now(:second)]], skip_tenant_check: true)

    expect(Engram.MockStorage, :delete, fn key ->
      assert key == up.storage_key
      :ok
    end)

    expect(Engram.MockStorage, :abort_multipart_upload, 0, fn _, _ -> :ok end)
    assert :ok = perform_job(AttachmentUploadExpiry, %{})
    refute exists?(up)
  end

  test "an assembled object a live attachment references is kept", ctx do
    up = start!(ctx.user, ctx.vault, "live.png")
    age!(up, 25)

    from(u in Upload, where: u.id == ^up.id)
    |> Repo.update_all([set: [assembled_at: DateTime.utc_now(:second)]], skip_tenant_check: true)

    insert(:attachment, user: ctx.user, vault: ctx.vault, storage_key: up.storage_key)

    expect(Engram.MockStorage, :delete, 0, fn _ -> :ok end)
    assert :ok = perform_job(AttachmentUploadExpiry, %{})
    refute exists?(up)
  end

  test "a storage failure does not stop the sweep", ctx do
    a = start!(ctx.user, ctx.vault, "a.png")
    b = start!(ctx.user, ctx.vault, "b.png")
    age!(a, 25)
    age!(b, 26)

    expect(Engram.MockStorage, :abort_multipart_upload, 2, fn _, _ -> {:error, :boom} end)
    assert :ok = perform_job(AttachmentUploadExpiry, %{})
    refute exists?(a)
    refute exists?(b)
  end

  # A completed session is kept so a retried complete gets its attachment;
  # its blob is the live attachment's, so expiry drops only the row.
  test "a completed session idle 25h is dropped with no storage call; 23h is kept", ctx do
    old = start!(ctx.user, ctx.vault, "old.png")
    new = start!(ctx.user, ctx.vault, "new.png")

    for up <- [old, new] do
      {:ok, _} = Uploads.put_part(ctx.user, ctx.vault, up.id, 1, "0123456789")
      {:ok, _} = Uploads.complete(ctx.user, ctx.vault, up.id)
    end

    age!(old, 25)
    age!(new, 23)

    expect(Engram.MockStorage, :delete, 0, fn _ -> :ok end)
    expect(Engram.MockStorage, :abort_multipart_upload, 0, fn _, _ -> :ok end)
    assert :ok = perform_job(AttachmentUploadExpiry, %{})
    refute exists?(old)
    assert exists?(new)
    assert InMemory.exists?(old.storage_key)
  end
end
