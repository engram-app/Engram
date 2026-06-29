defmodule Mix.Tasks.Engram.BackfillOnboardingActionsTest do
  use Engram.DataCase, async: false

  alias Engram.Onboarding
  alias Engram.Onboarding.Action
  alias Engram.Repo
  alias Engram.Vaults
  alias Mix.Tasks.Engram.BackfillOnboardingActions

  test "inserts first_vault_created for every user with at least one vault" do
    user_with = insert_user()
    user_without = insert_user()
    {:ok, _} = Vaults.create_vault(user_with, %{name: "Main"})

    # Simulate a legacy user: clear the row created by the T5 hook so the test
    # exercises pure backfill. Cross-tenant test cleanup — onboarding_actions is
    # now a tenant table (Engram#788), so the guard needs the explicit bypass.
    Repo.delete_all(Action, skip_tenant_check: true)

    BackfillOnboardingActions.run([])

    assert ["first_vault_created"] = Onboarding.list_actions(user_with.id)
    assert [] = Onboarding.list_actions(user_without.id)
  end

  test "idempotent — second run is a no-op" do
    user = insert_user()
    {:ok, _} = Vaults.create_vault(user, %{name: "Main"})

    BackfillOnboardingActions.run([])
    BackfillOnboardingActions.run([])

    assert ["first_vault_created"] = Onboarding.list_actions(user.id)
  end
end
