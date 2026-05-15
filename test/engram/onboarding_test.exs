defmodule Engram.OnboardingTest do
  use Engram.DataCase, async: false

  alias Engram.Onboarding
  alias Engram.Onboarding.Agreement

  describe "accept_terms/3" do
    test "inserts an agreement row for the user and version" do
      user = insert(:user)

      {:ok, %Agreement{} = agreement} =
        Onboarding.accept_terms(user, "2026-05-15", %{
          ip_address: "192.168.1.1",
          user_agent: "Mozilla/5.0"
        })

      assert agreement.user_id == user.id
      assert agreement.document == "terms_of_service"
      assert agreement.version == "2026-05-15"
      assert agreement.ip_address == "192.168.1.1"
      assert agreement.user_agent == "Mozilla/5.0"
      assert agreement.accepted_at != nil
    end

    test "allows the same user to accept multiple versions" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-01-01", %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      rows =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.all(Agreement)
        end)
        |> elem(1)

      assert length(rows) == 2
    end

    test "rejects empty version" do
      user = insert(:user)
      assert {:error, %Ecto.Changeset{}} = Onboarding.accept_terms(user, "", %{})
    end
  end

  describe "status/1 when billing is disabled (self-host)" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      prev_version = Application.get_env(:engram, :current_tos_version)
      Application.put_env(:engram, :billing_enabled, false)
      Application.put_env(:engram, :current_tos_version, "2026-05-15")
      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        Application.put_env(:engram, :current_tos_version, prev_version)
      end)
      :ok
    end

    test "returns enabled=false and next_step=done regardless of state" do
      user = insert(:user)
      assert %{enabled: false, next_step: :done} = Onboarding.status(user)
    end
  end

  describe "status/1 when billing is enabled" do
    setup do
      prev_enabled = Application.get_env(:engram, :billing_enabled)
      prev_version = Application.get_env(:engram, :current_tos_version)
      Application.put_env(:engram, :billing_enabled, true)
      Application.put_env(:engram, :current_tos_version, "2026-05-15")
      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev_enabled)
        Application.put_env(:engram, :current_tos_version, prev_version)
      end)
      :ok
    end

    test "next_step=agreement when user has no agreement and no subscription" do
      user = insert(:user)

      assert %{
               enabled: true,
               terms_ok: false,
               subscription_ok: false,
               current_tos_version: "2026-05-15",
               next_step: :agreement
             } = Onboarding.status(user)
    end

    test "next_step=billing when terms accepted but no subscription" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      assert %{terms_ok: true, subscription_ok: false, next_step: :billing} =
               Onboarding.status(user)
    end

    test "next_step=done when terms accepted and active subscription exists" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")

      assert %{terms_ok: true, subscription_ok: true, next_step: :done} =
               Onboarding.status(user)
    end

    test "next_step=agreement when accepted version is older than current_tos_version" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2025-01-01", %{})
      insert(:subscription, user: user, status: "active")

      assert %{terms_ok: false, subscription_ok: true, next_step: :agreement} =
               Onboarding.status(user)
    end

    test "next_step=done when terms accepted and past_due subscription exists" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "past_due")

      assert %{terms_ok: true, subscription_ok: true, next_step: :done} =
               Onboarding.status(user)
    end
  end
end
