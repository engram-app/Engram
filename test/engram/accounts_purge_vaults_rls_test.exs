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

  ## Do not append a tenant-table assertion after the purge call

  `Repo.with_tenant/2` resets the ROLE on exit but not `app.current_tenant`,
  so once `purge_user_vaults/1` returns, the tenant is still set for the rest
  of this closure. The `oban_jobs` counts below are unaffected because that
  table carries no policy. A `vaults` or `notes` assertion placed after the
  call would run WITH a tenant in force and pass regardless of the code under
  test — trap 2 in `docs/context/rls-enforcement-testing-traps.md`. Put any
  such assertion in its own `as_prod_role/1` block, which clears the tenant on
  entry.
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
    _second_vault = insert(:vault, user: user)

    # A bystander, whose VAULT id is what the assertion keys on. Keying it on
    # the bystander's user_id would pin nothing: the enqueue passes the outer
    # `user_id`, not `v.user_id`, so every job carries the purged user's id by
    # construction and that count is structurally unable to be non-zero. The
    # vault id does move — an over-broad read that loses its `user_id`
    # predicate enqueues a job carrying THIS vault's id.
    other = insert(:user, role: "member")
    other_vault = insert(:vault, user: other)

    %{user: user, vault: vault, other_vault: other_vault}
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

    test "every owned vault gets a forced CleanupVault, and only theirs",
         %{user: user, other_vault: other_vault} do
      # Worker-scoped: a bare `user_id` match would also count any other job
      # this path later enqueues keyed on the same user.
      count = fn field, value ->
        Repo.one(
          from(j in "oban_jobs",
            where:
              j.worker == "Engram.Workers.CleanupVault" and
                fragment("? ->> ? = ?", j.args, ^field, ^value),
            select: count(j.id)
          )
        )
      end

      outcome =
        as_prod_role(fn ->
          Accounts.purge_user_vaults(user)
          {count.("user_id", user.id), count.("vault_id", other_vault.id)}
        end)

      # The two elements pin opposite failures. `{0, _}` is the filtered-read
      # bug this file exists for. `{_, 1}` is an over-broad enumeration that
      # lost its `user_id` predicate — caught via the bystander's VAULT id,
      # because every job carries the purged user's id regardless.
      assert {:returned, {2, 0}} = outcome,
             """
             expected 2 CleanupVault jobs for the purged user and 0 for the
             bystander.

             `{0, 0}` means the `vaults` enumeration was filtered by the tenant
             policy, so an admin DELETE returns ok while nothing is reaped.
             A non-zero second element means the purge reached another user's
             vaults.

               got: #{inspect(outcome)}
             """
    end
  end
end
