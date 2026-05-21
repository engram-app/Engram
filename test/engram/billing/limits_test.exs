defmodule Engram.Billing.LimitsTest do
  use Engram.DataCase, async: true

  alias Engram.Billing
  alias Engram.Billing.Plan
  alias Engram.Repo

  # ── Helpers ──────────────────────────────────────────────────────

  defp insert_plan(limits) do
    Repo.insert!(%Plan{name: "plan_#{System.unique_integer([:positive])}", limits: limits})
  end

  defp insert_override(user_id, overrides_map) when is_map(overrides_map) do
    for {key, value} <- overrides_map do
      Repo.insert!(%Engram.Billing.UserLimitOverride{
        user_id: user_id,
        key: to_string(key),
        value: %{"v" => value},
        reason: "test",
        set_by: "test"
      })
    end
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
      plan = insert_plan(%{"vaults_cap" => 3})
      user = user_with_plan(plan)

      assert Billing.effective_limit(user, :vaults_cap) == 3
    end

    test "returns user override when it exists" do
      plan = insert_plan(%{"vaults_cap" => 1})
      user = user_with_plan(plan)
      insert_override(user.id, %{"vaults_cap" => 10})

      assert Billing.effective_limit(user, :vaults_cap) == 10
    end

    test "falls through to plan when override key is missing" do
      plan = insert_plan(%{"vaults_cap" => 5})
      user = user_with_plan(plan)
      insert_override(user.id, %{"some_other_key" => 99})

      assert Billing.effective_limit(user, :vaults_cap) == 5
    end

    test "falls through to default when plan key is also missing" do
      plan = insert_plan(%{})
      user = user_with_plan(plan)

      assert Billing.effective_limit(user, :vaults_cap) == 1
    end

    test "raises UnknownLimitKey for unknown atom key" do
      user = user_without_plan()

      assert_raise Engram.Billing.UnknownLimitKey, fn ->
        Billing.effective_limit(user, :nonexistent_feature)
      end
    end

    test "returns default limits when user has no plan (nil plan_id)" do
      user = user_without_plan()

      assert Billing.effective_limit(user, :vaults_cap) == 1
      assert Billing.effective_limit(user, :attachment_bytes_cap) == 1_073_741_824
      assert Billing.effective_limit(user, :cross_vault_search) == false
      assert Billing.effective_limit(user, :vault_scoped_keys) == false
    end

    test "returns false (not nil) for boolean features disabled in plan" do
      plan = insert_plan(%{"cross_vault_search" => false})
      user = user_with_plan(plan)

      result = Billing.effective_limit(user, :cross_vault_search)
      assert result == false
      refute is_nil(result)
    end

    test "returns override even when override value is false" do
      plan = insert_plan(%{"cross_vault_search" => true})
      user = user_with_plan(plan)
      insert_override(user.id, %{"cross_vault_search" => false})

      assert Billing.effective_limit(user, :cross_vault_search) == false
    end
  end

  # ── check_limit/3 ────────────────────────────────────────────────

  describe "check_limit/3" do
    test "returns :ok when current count is under the limit" do
      plan = insert_plan(%{"vaults_cap" => 3})
      user = user_with_plan(plan)

      assert Billing.check_limit(user, :vaults_cap, 2) == :ok
    end

    test "returns :ok when limit is -1 (unlimited)" do
      plan = insert_plan(%{"vaults_cap" => -1})
      user = user_with_plan(plan)

      assert Billing.check_limit(user, :vaults_cap, 9999) == :ok
    end

    test "returns error when current count is at the limit" do
      plan = insert_plan(%{"vaults_cap" => 2})
      user = user_with_plan(plan)

      assert Billing.check_limit(user, :vaults_cap, 2) == {:error, :limit_reached}
    end

    test "returns error when current count is over the limit" do
      plan = insert_plan(%{"vaults_cap" => 1})
      user = user_with_plan(plan)

      assert Billing.check_limit(user, :vaults_cap, 5) == {:error, :limit_reached}
    end

    test "uses default limit when user has no plan" do
      user = user_without_plan()

      # default vaults_cap is 1, so count 0 is ok
      assert Billing.check_limit(user, :vaults_cap, 0) == :ok
      # count 1 is at limit
      assert Billing.check_limit(user, :vaults_cap, 1) == {:error, :limit_reached}
    end
  end

  # ── check_feature/2 ──────────────────────────────────────────────

  describe "check_feature/2" do
    test "returns :ok when feature is enabled (true)" do
      plan = insert_plan(%{"cross_vault_search" => true})
      user = user_with_plan(plan)

      assert Billing.check_feature(user, :cross_vault_search) == :ok
    end

    test "returns error when feature is disabled (false)" do
      plan = insert_plan(%{"cross_vault_search" => false})
      user = user_with_plan(plan)

      assert Billing.check_feature(user, :cross_vault_search) == {:error, :feature_not_available}
    end

    test "returns error when feature defaults to false (no plan)" do
      user = user_without_plan()

      assert Billing.check_feature(user, :cross_vault_search) == {:error, :feature_not_available}
      assert Billing.check_feature(user, :vault_scoped_keys) == {:error, :feature_not_available}
    end

    test "returns :ok when override enables a feature the plan disables" do
      plan = insert_plan(%{"cross_vault_search" => false})
      user = user_with_plan(plan)
      insert_override(user.id, %{"cross_vault_search" => true})

      assert Billing.check_feature(user, :cross_vault_search) == :ok
    end
  end

  describe "atom-only API (Phase A)" do
    test "raises UnknownLimitKey on string key" do
      user = user_without_plan()

      assert_raise Engram.Billing.UnknownLimitKey, fn ->
        Billing.effective_limit(user, "notes_cap")
      end
    end

    test "raises UnknownLimitKey on unknown atom" do
      user = user_without_plan()

      assert_raise Engram.Billing.UnknownLimitKey, fn ->
        Billing.effective_limit(user, :bogus_key)
      end
    end

    test "accepts atom from LimitKeys catalog" do
      plan = insert_plan(%{"vaults_cap" => 7})
      user = user_with_plan(plan)

      assert Billing.effective_limit(user, :vaults_cap) == 7
    end
  end

  describe "bypass (self-host) — :limits_enforced=false" do
    setup do
      original = Application.get_env(:engram, :limits_enforced)
      Application.put_env(:engram, :limits_enforced, false)
      on_exit(fn -> Application.put_env(:engram, :limits_enforced, original) end)
      :ok
    end

    test "effective_limit returns :unlimited regardless of plan or override" do
      plan = insert_plan(%{"vaults_cap" => 1})
      user = user_with_plan(plan)
      insert_override(user.id, %{"vaults_cap" => 2})

      assert Billing.effective_limit(user, :vaults_cap) == :unlimited
    end

    test "check_limit returns :ok for any count" do
      plan = insert_plan(%{"vaults_cap" => 1})
      user = user_with_plan(plan)

      assert Billing.check_limit(user, :vaults_cap, 99_999) == :ok
    end

    test "check_feature returns :ok even when plan disables it" do
      plan = insert_plan(%{"reranker_enabled" => false})
      user = user_with_plan(plan)

      assert Billing.check_feature(user, :reranker_enabled) == :ok
    end

    test "still raises UnknownLimitKey on bad atom (catalog guard fires before bypass)" do
      user = user_without_plan()

      assert_raise Engram.Billing.UnknownLimitKey, fn ->
        Billing.effective_limit(user, :bogus_key)
      end
    end
  end

  describe "default (SaaS) — :limits_enforced=true" do
    setup do
      original = Application.get_env(:engram, :limits_enforced)
      Application.put_env(:engram, :limits_enforced, true)
      on_exit(fn -> Application.put_env(:engram, :limits_enforced, original) end)
      :ok
    end

    test "effective_limit runs normal 4-layer resolution" do
      plan = insert_plan(%{"vaults_cap" => 5})
      user = user_with_plan(plan)

      assert Billing.effective_limit(user, :vaults_cap) == 5
    end
  end

  describe "env-var override layer (layer 2)" do
    setup do
      original = Application.get_env(:engram, :plan_overrides)
      on_exit(fn -> Application.put_env(:engram, :plan_overrides, original || %{}) end)
      :ok
    end

    test "env override wins over plan default" do
      plan = insert_plan(%{"vaults_cap" => 5})
      user = user_with_plan(plan)

      Application.put_env(:engram, :plan_overrides, %{{:free, :vaults_cap} => 99})

      assert Billing.effective_limit(user, :vaults_cap) == 99
    end

    test "user override wins over env override" do
      plan = insert_plan(%{"vaults_cap" => 5})
      user = user_with_plan(plan)
      insert_override(user.id, %{"vaults_cap" => 7})

      Application.put_env(:engram, :plan_overrides, %{{:free, :vaults_cap} => 99})

      assert Billing.effective_limit(user, :vaults_cap) == 7
    end

    test "env override falls through when key not set" do
      plan = insert_plan(%{"vaults_cap" => 5})
      user = user_with_plan(plan)

      Application.put_env(:engram, :plan_overrides, %{{:free, :notes_cap} => 12_345})

      assert Billing.effective_limit(user, :vaults_cap) == 5
    end
  end

  describe "boolean false honored at every layer" do
    setup do
      original = Application.get_env(:engram, :plan_overrides)
      on_exit(fn -> Application.put_env(:engram, :plan_overrides, original || %{}) end)
      :ok
    end

    test "false from user override wins (not treated as missing)" do
      plan = insert_plan(%{"reranker_enabled" => true})
      user = user_with_plan(plan)
      insert_override(user.id, %{"reranker_enabled" => false})

      assert Billing.effective_limit(user, :reranker_enabled) == false
    end

    test "false from env override wins (not treated as missing)" do
      plan = insert_plan(%{"reranker_enabled" => true})
      user = user_with_plan(plan)

      Application.put_env(:engram, :plan_overrides, %{{:free, :reranker_enabled} => false})

      assert Billing.effective_limit(user, :reranker_enabled) == false
    end

    test "false from plan wins (not treated as missing)" do
      plan = insert_plan(%{"reranker_enabled" => false})
      user = user_with_plan(plan)

      assert Billing.effective_limit(user, :reranker_enabled) == false
    end

    test "false from catalog default wins" do
      # Empty plan + free tier → catalog default = false for :reranker_enabled
      plan = insert_plan(%{})
      user = user_with_plan(plan)

      assert Billing.effective_limit(user, :reranker_enabled) == false
    end
  end

  describe "expired user_limit_overrides ignored" do
    test "row with expires_at < now is not returned" do
      plan = insert_plan(%{"vaults_cap" => 5})
      user = user_with_plan(plan)

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.insert!(%Engram.Billing.UserLimitOverride{
        user_id: user.id,
        key: "vaults_cap",
        value: %{"v" => 999},
        reason: "expired test",
        set_by: "test",
        expires_at: past
      })

      assert Billing.effective_limit(user, :vaults_cap) == 5
    end

    test "row with expires_at IN FUTURE is returned" do
      plan = insert_plan(%{"vaults_cap" => 5})
      user = user_with_plan(plan)

      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      Repo.insert!(%Engram.Billing.UserLimitOverride{
        user_id: user.id,
        key: "vaults_cap",
        value: %{"v" => 999},
        reason: "future test",
        set_by: "test",
        expires_at: future
      })

      assert Billing.effective_limit(user, :vaults_cap) == 999
    end

    test "row with expires_at IS NULL is returned (permanent)" do
      plan = insert_plan(%{"vaults_cap" => 5})
      user = user_with_plan(plan)

      Repo.insert!(%Engram.Billing.UserLimitOverride{
        user_id: user.id,
        key: "vaults_cap",
        value: %{"v" => 999},
        reason: "permanent",
        set_by: "test"
      })

      assert Billing.effective_limit(user, :vaults_cap) == 999
    end
  end
end
