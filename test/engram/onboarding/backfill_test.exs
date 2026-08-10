defmodule Engram.Onboarding.BackfillTest do
  # Calls first_vault_created/0 directly — no Mix.Task in the path, which is
  # how release rpc invokes it (#1311). The mix-task test covers the wrapper.
  use Engram.DataCase, async: false

  alias Engram.Onboarding
  alias Engram.Onboarding.Action
  alias Engram.Onboarding.Backfill
  alias Engram.Repo
  alias Engram.Vaults

  test "records first_vault_created for every user holding a vault, and no one else" do
    user_with = insert_user()
    user_without = insert_user()
    {:ok, _} = Vaults.create_vault(user_with, %{name: "Main"})

    # Clear the row the T5 hook creates so this exercises pure backfill.
    # Cross-tenant test cleanup — onboarding_actions is a tenant table (#788).
    Repo.delete_all(Action, skip_tenant_check: true)

    assert Backfill.first_vault_created() == 1

    assert ["first_vault_created"] = Onboarding.list_actions(user_with.id)
    assert [] = Onboarding.list_actions(user_without.id)
  end

  test "is idempotent — a second run inserts nothing" do
    user = insert_user()
    {:ok, _} = Vaults.create_vault(user, %{name: "Main"})
    Repo.delete_all(Action, skip_tenant_check: true)

    assert Backfill.first_vault_created() == 1
    assert Backfill.first_vault_created() == 0

    assert ["first_vault_created"] = Onboarding.list_actions(user.id)
  end
end
