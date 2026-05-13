defmodule Engram.Billing.LimitsTest do
  use Engram.DataCase, async: true

  alias Engram.Billing
  alias Engram.Billing.UserOverride

  # ── Helpers ──────────────────────────────────────────────────────

  defp insert_plan(limits) do
    Repo.insert!(%Plan{name: "plan_#{System.unique_integer([:positive])}", limits: limits})
  end

  defp insert_override(user_id, overrides) do
    Repo.insert!(%UserOverride{user_id: user_id, overrides: overrides, reason: "test"})
  end

  defp user_with_plan(plan) do
    user = insert(:user)
    Repo.update!(Ecto.Changeset.change(user, plan_id: plan.id))
  end

  defp user_without_plan do
    insert(:user)
  end

  # ── effective_limit/2 ────────────────────────────────────────────

  describe "effective_limit/2" do
    test "returns plan default when no override exists" do
      plan = insert_plan(%{"max_vaults" => 3})
      user = user_with_plan(plan)

      assert Billing.effective_limit(user, "max_vaults") == 3
    end

    test "returns user override when it exists" do
      plan = insert_plan(%{"max_vaults" => 1})
      user = user_with_plan(plan)
      insert_override(user.id, %{"max_vaults" => 10})

      assert Billing.effective_limit(user, "max_vaults") == 10
    end

    test "falls through to plan when override key is missing" do
      plan = insert_plan(%{"max_vaults" => 5})
      user = user_with_plan(plan)
      insert_override(user.id, %{"some_other_key" => 99})

      assert Billing.effective_limit(user, "max_vaults") == 5
    end

    test "falls through to default when plan key is also missing" do
      plan = insert_plan(%{})
      user = user_with_plan(plan)

      assert Billing.effective_limit(user, "max_vaults") == 1
    end

    test "returns nil for unknown key not in defaults" do
      user = user_without_plan()

      assert Billing.effective_limit(user, "nonexistent_feature") == nil
    end

    test "returns default limits when user has no plan (nil plan_id)" do
      user = user_without_plan()

      assert Billing.effective_limit(user, "max_vaults") == 1
      assert Billing.effective_limit(user, "max_storage_bytes") == 104_857_600
      assert Billing.effective_limit(user, "cross_vault_search") == false
      assert Billing.effective_limit(user, "vault_scoped_keys") == false
    end

    test "returns false (not nil) for boolean features disabled in plan" do
      plan = insert_plan(%{"cross_vault_search" => false})
      user = user_with_plan(plan)

      result = Billing.effective_limit(user, "cross_vault_search")
      assert result == false
      refute is_nil(result)
    end

    test "returns override even when override value is false" do
      plan = insert_plan(%{"cross_vault_search" => true})
      user = user_with_plan(plan)
      insert_override(user.id, %{"cross_vault_search" => false})

      assert Billing.effective_limit(user, "cross_vault_search") == false
    end
  end

  # ── check_limit/3 ────────────────────────────────────────────────

  describe "check_limit/3" do
    test "returns :ok when current count is under the limit" do
      plan = insert_plan(%{"max_vaults" => 3})
      user = user_with_plan(plan)

      assert Billing.check_limit(user, "max_vaults", 2) == :ok
    end

    test "returns :ok when limit is -1 (unlimited)" do
      plan = insert_plan(%{"max_vaults" => -1})
      user = user_with_plan(plan)

      assert Billing.check_limit(user, "max_vaults", 9999) == :ok
    end

    test "returns error when current count is at the limit" do
      plan = insert_plan(%{"max_vaults" => 2})
      user = user_with_plan(plan)

      assert Billing.check_limit(user, "max_vaults", 2) == {:error, :limit_reached}
    end

    test "returns error when current count is over the limit" do
      plan = insert_plan(%{"max_vaults" => 1})
      user = user_with_plan(plan)

      assert Billing.check_limit(user, "max_vaults", 5) == {:error, :limit_reached}
    end

    test "uses default limit when user has no plan" do
      user = user_without_plan()

      # default max_vaults is 1, so count 0 is ok
      assert Billing.check_limit(user, "max_vaults", 0) == :ok
      # count 1 is at limit
      assert Billing.check_limit(user, "max_vaults", 1) == {:error, :limit_reached}
    end
  end

  # ── check_feature/2 ──────────────────────────────────────────────

  describe "check_feature/2" do
    test "returns :ok when feature is enabled (true)" do
      plan = insert_plan(%{"cross_vault_search" => true})
      user = user_with_plan(plan)

      assert Billing.check_feature(user, "cross_vault_search") == :ok
    end

    test "returns error when feature is disabled (false)" do
      plan = insert_plan(%{"cross_vault_search" => false})
      user = user_with_plan(plan)

      assert Billing.check_feature(user, "cross_vault_search") == {:error, :feature_not_available}
    end

    test "returns error when feature defaults to false (no plan)" do
      user = user_without_plan()

      assert Billing.check_feature(user, "cross_vault_search") == {:error, :feature_not_available}
      assert Billing.check_feature(user, "vault_scoped_keys") == {:error, :feature_not_available}
    end

    test "returns :ok when override enables a feature the plan disables" do
      plan = insert_plan(%{"cross_vault_search" => false})
      user = user_with_plan(plan)
      insert_override(user.id, %{"cross_vault_search" => true})

      assert Billing.check_feature(user, "cross_vault_search") == :ok
    end
  end
end
