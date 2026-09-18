defmodule Engram.AccountsPurgeVaultsRlsTest do
  @moduledoc """
  Pins `Accounts.purge_user_vaults/1` against an ENFORCED row-level security
  policy.

  ## What breaks

  `vaults` carries FORCE ROW LEVEL SECURITY. `purge_user_vaults/1` enumerated
  it with `skip_tenant_check: true` and no enclosing `with_tenant`:

      Repo.all(
        from(v in Engram.Vaults.Vault, where: v.user_id == ^user_id),
        skip_tenant_check: true
      )
      |> Enum.each(fn v -> CleanupVault.enqueue_now(v.id, user_id) end)

  `skip_tenant_check:` silences the application-level `prepare_query/3`
  tripwire and sets no Postgres session state, so the policy still applies.
  Unscoped the read returns `[]`, `Enum.each/2` iterates nothing, and the
  function returns `:ok` having enqueued no jobs.

  That is the silent-failure shape: the admin DELETE endpoint
  (`EngramWeb.Admin.UserController.delete/2`, Spec §7) reports `{"ok": true}`
  while the user's vault data, attachments and storage blobs are never
  reaped. Nothing raises and nothing logs.

  The old docstring actively licensed it — "Bypasses RLS + the
  `Vaults.list_vaults/1` DEK-decrypt chain, since the purge only needs vault
  ids". Skipping the decrypt chain is the legitimate half; "bypasses RLS" was
  never true of `skip_tenant_check:`, which is exactly the inversion
  `docs/context/skip-tenant-check-audit.md` exists to record.

  ## Why the assertion happens inside the closure

  `as_prod_role/1` rolls back, which would discard the `oban_jobs` rows the
  assertion counts. Counting inside the closure keeps the harness rolling back
  (right, because nothing here needs to persist) while still observing the
  effect.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Accounts
  alias Engram.Repo
  alias Engram.Vaults.Vault

  setup do
    user = insert(:user, role: "member")
    vault = insert(:vault, user: user)

    %{user: user, vault: vault}
  end

  describe "purge_user_vaults/1 under enforced RLS" do
    # CONTROL. Without it a green file cannot distinguish "correctly scoped"
    # from "the role drop never engaged".
    test "control: the dropped role cannot see the user's vaults", %{user: user} do
      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.one(
                   from(v in Vault, where: v.user_id == ^user.id, select: count(v.id)),
                   skip_tenant_check: true
                 )
               end)
    end

    test "every owned vault still gets a forced CleanupVault", %{user: user, vault: vault} do
      outcome =
        as_prod_role(fn ->
          Accounts.purge_user_vaults(user)

          Repo.one(
            from(j in "oban_jobs",
              where: fragment("? ->> 'vault_id' = ?", j.args, ^vault.id),
              select: count(j.id)
            ),
            skip_tenant_check: true
          )
        end)

      assert {:returned, 1} = outcome,
             """
             purge_user_vaults/1 enqueued nothing: the `vaults` enumeration was
             filtered by the tenant policy, so an admin DELETE returns ok while
             the user's vault data is never reaped.

               got: #{inspect(outcome)}
             """
    end
  end
end
