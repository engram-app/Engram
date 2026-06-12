defmodule EngramWeb.Plugs.RequireOnboardingTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias EngramWeb.Plugs.RequireOnboarding

  setup do
    prev_enabled = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)

    LegalFixtures.insert_version(
      document: "terms_of_service",
      version: "2026-05-15",
      content_hash: "canonical",
      material: true,
      effective_date: nil
    )

    LegalFixtures.insert_version(
      document: "privacy_policy",
      version: "2026-05-15",
      content_hash: "p",
      material: true,
      effective_date: nil
    )

    VersionCache.invalidate_all()
    on_exit(&VersionCache.invalidate_all/0)

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_enabled)
    end)

    :ok
  end

  test "self-host (billing disabled) still gates on profile + vault", %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, false)
    user = insert(:user, onboarding_profile: %{})

    # Fresh self-host user: agreement + billing auto-pass, but profile is empty
    # so the plug halts pointing at the profile step.
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["missing"] == ["profile"]
    assert body["next_step"] == "tools"
  end

  test "self-host passes through once profile is set (obsidian path)", %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, false)
    user = insert(:user, onboarding_profile: %{})
    {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    refute conn.halted
  end

  test "halts 403 with missing=[profile,subscription,terms] when all three gates fail",
       %{conn: conn} do
    user = insert(:user, onboarding_profile: %{})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["error"] == "onboarding_required"
    assert Enum.sort(body["missing"]) == ["profile", "subscription", "terms"]
  end

  test "halts 403 with missing=[profile,subscription] when only terms is satisfied",
       %{conn: conn} do
    user = insert(:user, onboarding_profile: %{})
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert Enum.sort(body["missing"]) == ["profile", "subscription"]
  end

  test "halts 403 with missing=[profile,terms] when only subscription is satisfied",
       %{conn: conn} do
    user = insert(:user, onboarding_profile: %{})
    insert(:subscription, user: user, status: "active")
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["missing"] == ["profile", "terms"]
  end

  test "halts 403 with missing=[vault] when fresh-path profile is set but no vault",
       %{conn: conn} do
    user = insert(:user, onboarding_profile: %{})
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "active")
    {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["missing"] == ["vault"]
    assert body["next_step"] == "vault"
  end

  test "passes through for obsidian users without a vault (plugin creates it)",
       %{conn: conn} do
    user = insert(:user, onboarding_profile: %{})
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "active")
    {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    refute conn.halted
  end

  test "halts 403 with missing=[profile] when terms+subscription ok but profile incomplete",
       %{conn: conn} do
    user = insert(:user, onboarding_profile: %{})
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "active")
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["missing"] == ["profile"]
    assert body["next_step"] == "tools"
  end

  test "passes through when fresh-path profile is set AND a vault exists",
       %{conn: conn} do
    user = insert(:user, onboarding_profile: %{})
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "active")
    {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})
    {:ok, _} = Engram.Vaults.create_vault(user, %{name: "My Vault"})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    refute conn.halted
  end

  test "halts 401 (not crashes) when current_user assign is missing", %{conn: conn} do
    conn = RequireOnboarding.call(conn, [])
    assert conn.halted
    assert conn.status == 401
    body = Phoenix.ConnTest.json_response(conn, 401)
    assert body["error"] == "authentication_required"
  end

  test "401 path is safe even when billing is disabled", %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, false)
    conn = RequireOnboarding.call(conn, [])
    assert conn.halted
    assert conn.status == 401
  end

  test "403 body includes next_step matching first missing gate", %{conn: conn} do
    user = insert(:user, onboarding_profile: %{})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["next_step"] == "agreement"
  end

  test "403 next_step is 'billing' when terms accepted but no subscription", %{conn: conn} do
    user = insert(:user, onboarding_profile: %{})
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["next_step"] == "billing"
  end

  test "403 includes Content-Type application/json", %{conn: conn} do
    user = insert(:user, onboarding_profile: %{})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert Plug.Conn.get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
  end

  describe "pass-verdict caching" do
    alias Engram.Onboarding.GateCache

    setup do
      on_exit(fn -> GateCache.evict_all() end)
      :ok
    end

    defp passed_user do
      user = insert(:user, onboarding_profile: %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "My Vault"})
      {user, vault}
    end

    test "a passing request populates the cache and short-circuits the next one",
         %{conn: conn} do
      {user, vault} = passed_user()

      first = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
      refute first.halted
      assert GateCache.passed?(user.id)

      # Break the underlying state WITHOUT going through the context (no
      # eviction fires): the cached verdict must short-circuit — proving the
      # plug no longer re-derives status per request.
      import Ecto.Query

      Engram.Repo.update_all(
        from(v in Engram.Vaults.Vault, where: v.id == ^vault.id),
        [set: [deleted_at: DateTime.utc_now(:second)]],
        skip_tenant_check: true
      )

      second = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
      refute second.halted
    end

    test "context vault deletion evicts the verdict and the gate re-derives",
         %{conn: conn} do
      {user, vault} = passed_user()

      first = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
      refute first.halted

      {:ok, _} = Engram.Vaults.delete_vault(user, vault.id)

      second = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
      assert second.halted
      assert second.status == 403
      body = Phoenix.ConnTest.json_response(second, 403)
      assert body["missing"] == ["vault"]
    end
  end
end
