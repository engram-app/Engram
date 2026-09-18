defmodule Engram.Accounts.LifecycleRlsTest.TenantClearingStorage do
  @moduledoc """
  Storage adapter that clears the leaked tenant, then delegates to `InMemory`.

  This exists to reproduce a PRODUCTION condition the sandbox otherwise makes
  unreachable, and it is the only way this bug can be tested through the real
  `hard_delete/2` entry point.

  `do_hard_delete/2` calls `drop_qdrant_for_user/1` (Step 2) before its commit
  point (Step 4). That leg runs `Repo.with_tenant/2`, whose `SET LOCAL` is
  scoped to its own transaction — in production it dies when that transaction
  ends, so the commit point runs with NO tenant. Under the Ecto sandbox every
  test is wrapped in one enclosing transaction, so the same `SET LOCAL` LEAKS
  FORWARD and is still in force at the commit point, where it satisfies the
  vaults policy and lets the delete succeed. That is the documented
  leak-forward trap in `docs/context/rls-enforcement-testing-traps.md`, and it
  made this test pass against genuinely broken code.

  `wipe_storage_prefix/2` (Step 3) runs between the leak and the commit point,
  and the adapter is already swapped out in this test, so clearing the tenant
  here lands it exactly where production would have it: empty.
  """

  alias Engram.Repo
  alias Engram.Storage.InMemory

  def delete_prefix(prefix) do
    Repo.query!("SELECT set_config('app.current_tenant', '', true)")
    InMemory.delete_prefix(prefix)
  end
end

defmodule Engram.Accounts.LifecycleRlsTest do
  @moduledoc """
  Pins account hard-delete against an ENFORCED row-level security policy.

  ## What breaks

  `do_hard_delete/2`'s commit point deletes the user's vaults and then the user
  row, in one transaction, in that order. The order is load-bearing and the
  code says why: `notes.user_id`, `attachments.user_id` and `chunks.user_id`
  reference `users` WITHOUT `ON DELETE CASCADE`, so the vault delete is what
  transitively clears them (their `vault_id` FKs do cascade) and opens the path
  for `Repo.delete!(user)`.

  `vaults` carries `FORCE ROW LEVEL SECURITY`. Unscoped, that `delete_all` is
  FILTERED to zero rows — no error — so nothing cascades, and the subsequent
  delete of the user row hits an FK violation from the notes that are still
  pointing at it. Account deletion cannot complete at all.

  That makes this one of the louder bucket-D sites, but loud in the wrong
  place: the operator sees a Postgres FK error about `notes`, not "tenant
  scoping", and the moduledoc advertises `{:error, :pg_failed}` as "recoverable
  on retry" — which it is not, since every retry fails identically.

  ## Why `lifecycle_test.exs` passes today

  Its `hard_delete/2` block already asserts the user row is gone and the S3
  blobs are collected, and it passes regardless: the suite connects as a
  Postgres superuser, and a superuser bypasses RLS even under `FORCE`.

  The COMMITTING harness is required — the claim is about rows being gone
  afterwards, and the rolling-back variant would discard the deletes under test
  and pass against a completely unscoped implementation. See the warning on
  `Engram.RlsCase.as_prod_role/1`.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Accounts.Lifecycle
  alias Engram.Accounts.User
  alias Engram.Repo
  alias Engram.Storage.InMemory
  alias Engram.Vaults.Vault

  setup do
    InMemory.ensure_table()

    prev_storage = Application.get_env(:engram, :storage)

    Application.put_env(
      :engram,
      :storage,
      Engram.Accounts.LifecycleRlsTest.TenantClearingStorage
    )

    on_exit(fn ->
      if is_nil(prev_storage),
        do: Application.delete_env(:engram, :storage),
        else: Application.put_env(:engram, :storage, prev_storage)
    end)

    # external_id: nil and no subscription, so the Clerk and Paddle legs
    # short-circuit and this test is about the Postgres cascade only.
    user = insert(:user, external_id: nil)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    InMemory.put("#{user.id}/vault1/file.png", "binary")

    %{user: user, vault: vault, note: note}
  end

  describe "hard_delete/2 under enforced RLS" do
    # CONTROL. `users` is NOT a tenant table, so the user row stays visible
    # under the dropped role — the thing the policy hides is the VAULT, which
    # is exactly what the cascade depends on. Without this, a green file cannot
    # distinguish correct scoping from a role drop that never engaged.
    test "control: the dropped role cannot see the user's vault", %{vault: vault} do
      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.one(
                   from(v in Vault, where: v.id == ^vault.id, select: count(v.id)),
                   skip_tenant_check: true
                 )
               end)
    end

    test "completes the cascade instead of failing on an FK violation", %{
      user: user,
      vault: vault,
      note: note
    } do
      # Ids captured BEFORE the delete. Reloading them afterwards would return
      # nil and make every assertion below pass unconditionally.
      user_id = user.id
      vault_id = vault.id
      note_id = note.id

      # Unscoped, the vault delete is filtered to zero rows, nothing cascades,
      # and `Repo.delete!(user)` then hits an FK violation from the note still
      # referencing this user.
      as_prod_role_committing(fn -> Lifecycle.hard_delete(user, :user) end)

      # Read back as the superuser — reading inside the dropped role would be
      # filtered too, and these would pass while the rows survived.
      refute Repo.get(User, user_id, skip_tenant_check: true)
      refute Repo.get(Vault, vault_id, skip_tenant_check: true)

      # The note is the row whose FK blocks the user delete, so its absence is
      # what proves the cascade actually ran rather than being skipped.
      refute Repo.get(Engram.Notes.Note, note_id, skip_tenant_check: true)
    end
  end
end
