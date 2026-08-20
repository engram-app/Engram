defmodule Engram.OnboardingGateTest do
  @moduledoc """
  Direct unit tests for `Engram.Onboarding.gate/2` — the verdict function both
  the HTTP plug and the `sync:`/`crdt:` channel joins delegate to. Everything
  else tests it through a transport; this pins the contract itself.
  """
  use Engram.DataCase, async: false

  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.GateCache

  setup do
    prev = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)

    LegalFixtures.insert_version(
      document: "terms_of_service",
      version: "2026-05-15",
      content_hash: "canonical",
      material: true,
      effective_date: nil
    )

    VersionCache.invalidate_all()
    GateCache.evict_all()

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev)
      VersionCache.invalidate_all()
      GateCache.evict_all()
    end)

    :ok
  end

  test "a fresh account is missing terms and subscription" do
    user = insert_user(onboarding_profile: %{})
    assert {:error, missing, :agreement} = Onboarding.gate(user)
    assert "terms" in missing
    assert "subscription" in missing
    assert "profile" in missing
  end

  test "passing marks the cache; failing never does" do
    blocked = insert_user(onboarding_profile: %{})
    assert {:error, _, _} = Onboarding.gate(blocked)
    refute GateCache.passed?(blocked.id), "a FAIL verdict must not be cached"

    passing = onboarded_user()
    assert :ok = Onboarding.gate(passing)
    assert GateCache.passed?(passing.id)
  end

  test "uses_obsidian bypasses the vault requirement; the fresh path does not" do
    obsidian = onboarded_user(uses_obsidian: true)
    refute Engram.Vaults.has_vault?(obsidian)
    assert :ok = Onboarding.gate(obsidian)

    fresh = onboarded_user(uses_obsidian: false)
    refute Engram.Vaults.has_vault?(fresh)
    assert {:error, ["vault"], _} = Onboarding.gate(fresh)
  end

  test "skip_vault relaxes ONLY the vault rule" do
    fresh = onboarded_user(uses_obsidian: false)
    assert {:error, ["vault"], _} = Onboarding.gate(fresh)
    assert :ok = Onboarding.gate(fresh, skip_vault: true)

    # Still gated on everything else.
    blocked = insert_user(onboarding_profile: %{})
    assert {:error, missing, _} = Onboarding.gate(blocked, skip_vault: true)
    assert "terms" in missing
    assert "subscription" in missing
  end

  test "self-host disables terms and billing, NOT profile" do
    Application.put_env(:engram, :billing_enabled, false)
    GateCache.evict_all()

    user = insert_user(onboarding_profile: %{})
    assert {:error, ["profile"], _} = Onboarding.gate(user)

    {:ok, done} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
    GateCache.evict_all()
    assert :ok = Onboarding.gate(done)
  end

  defp onboarded_user(opts \\ []) do
    uses_obsidian = Keyword.get(opts, :uses_obsidian, true)
    user = insert_user(onboarding_profile: %{})
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, user} = Onboarding.accept_free_tier(user)
    {:ok, user} = Onboarding.set_profile(user, %{uses_obsidian: uses_obsidian, tools: ["claude"]})
    GateCache.evict_all()
    user
  end
end
