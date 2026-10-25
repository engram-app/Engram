defmodule Engram.Attachments.ReviveTombstonesLockTest do
  @moduledoc """
  #2195, the lock half: `revive_tombstones/3` takes the vault row lock BEFORE
  it reads eligibility, so a GC claim that is still open (vault locked, the
  stamp not yet written) makes the revive wait, and once the claim commits
  the revive sees it and refuses. Without the lock first, the revive would
  read the row unclaimed and bring it back while the GC deletes its blob.

  Two real transactions on two connections, so the rows are committed
  outside the sandbox and deleted on exit (the pattern in
  `attachment_blob_gc_maintenance_test.exs`).
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Attachments, Repo}
  alias Engram.Attachments.Attachment

  setup do
    {user, vault, att} =
      Sandbox.unboxed_run(Repo, fn ->
        user = insert(:user)
        vault = insert(:vault, user: user)

        att =
          insert(:attachment,
            user: user,
            vault: vault,
            storage_key: "#{user.id}/#{vault.id}/objects/#{Ecto.UUID.generate()}",
            deleted_at: DateTime.add(DateTime.utc_now(:second), -40, :day)
          )

        {user, vault, att}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        uid = Ecto.UUID.dump!(user.id)
        Repo.query!("DELETE FROM attachments WHERE user_id = $1", [uid])
        Repo.query!("DELETE FROM vaults WHERE user_id = $1", [uid])
        Repo.query!("DELETE FROM users WHERE id = $1", [uid])
      end)
    end)

    %{user: user, vault: vault, att: att}
  end

  test "a revive waits on an open GC claim, then refuses it", %{
    user: user,
    vault: vault,
    att: att
  } do
    test_pid = self()

    # The GC claim's shape: vault row FOR NO KEY UPDATE, then the stamp,
    # held open until told to commit.
    claim =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT 1 FROM vaults WHERE id = $1 FOR NO KEY UPDATE", [
              Ecto.UUID.dump!(vault.id)
            ])

            # Vault lock held, the row not touched yet: only the vault lock
            # can make the revive wait here (the row lock comes later).
            send(test_pid, :claim_open)
            receive do: (:commit -> :ok)

            Repo.update_all(
              from(a in Attachment, where: a.id == ^att.id),
              [set: [blob_gc_claimed_at: DateTime.utc_now()]],
              skip_tenant_check: true
            )
          end)
        end)
      end)

    assert_receive :claim_open, 5_000

    revive =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Attachments.revive_tombstones(user, vault, [att.id])
        end)
      end)

    assert Task.yield(revive, 500) == nil, "the revive did not wait on the vault lock"

    send(claim.pid, :commit)
    Task.await(claim, 5_000)

    assert {:ok, %{restored: [], unrestored: [id]}} = Task.await(revive, 5_000)
    assert id == att.id
  end
end
