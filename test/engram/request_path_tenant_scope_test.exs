defmodule Engram.RequestPathTenantScopeTest do
  @moduledoc """
  Regression guard for #1354.

  These functions sit on the onboarding request path and read/write
  FORCE-RLS tenant tables. Before #1354 they passed `skip_tenant_check: true`
  with no `app.current_tenant` set, which on prod means the policy filters
  every row (reads return empty) or the WITH CHECK fails (writes raise).

  Verified against prod on 2026-08-10 via the read-only bastion:

      engram_admin  super=false  bypassrls=false   (owner of every tenant table)
      onboarding_actions / vaults   rls=true  force=true

  `FORCE` binds even the owner, and no role on the instance has BYPASSRLS —
  RDS will not grant it. So the unscoped form genuinely returned zero.

  **A value assertion cannot catch this.** Dev and CI connect as a superuser,
  which bypasses RLS regardless of FORCE, so `assert actions == ["x"]` passes
  identically before and after the fix. What is asserted instead is
  structural: these calls must emit no `[:engram, :repo, :tenant_check_skipped]`
  telemetry, which `Engram.Repo` fires whenever the guard is skipped. That
  holds on any Postgres role.
  """
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Onboarding
  alias Engram.Vaults

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Vaults.register_vault(user, "RequestScope", Ecto.UUID.generate())

    %{user: user, vault: vault}
  end

  defp skipped_tables(fun) do
    handler_id = "req-scope-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :tenant_check_skipped],
      fn _e, _m, meta, _c -> send(parent, {:skipped, meta[:table]}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    fun.()
    drain([])
  end

  defp drain(acc) do
    receive do
      {:skipped, t} -> drain([t | acc])
    after
      0 -> acc |> Enum.uniq() |> Enum.sort()
    end
  end

  test "Onboarding.list_actions/1 reads inside its tenant context", %{user: user} do
    :ok = Onboarding.record_action(user.id, "first_vault_created")

    assert skipped_tables(fn ->
             assert "first_vault_created" in Onboarding.list_actions(user.id)
           end) == []
  end

  test "Onboarding.record_action/2 writes inside its tenant context", %{user: user} do
    assert skipped_tables(fn ->
             assert :ok = Onboarding.record_action(user.id, "plugin_connected")
           end) == []
  end

  test "Vaults.count_for/1 counts inside its tenant context", %{user: user} do
    assert skipped_tables(fn ->
             assert Vaults.count_for(user) >= 1
           end) == []
  end

  # The whole payload in one pass — this is what the wizard actually calls, and
  # it is the combination that was wrong on prod (no vaults AND no actions).
  test "the onboarding status payload takes no unscoped tenant read", %{user: user} do
    assert skipped_tables(fn ->
             payload = EngramWeb.OnboardingController.status_payload(user)
             assert payload.vault_count >= 1
           end) == []
  end
end
