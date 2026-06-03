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

  test "passes through when billing is disabled (self-host)", %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, false)
    user = insert(:user)
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    refute conn.halted
  end

  test "halts 403 with missing=[profile,subscription,terms] when all three gates fail",
       %{conn: conn} do
    user = insert(:user)
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["error"] == "onboarding_required"
    assert Enum.sort(body["missing"]) == ["profile", "subscription", "terms"]
  end

  test "halts 403 with missing=[profile,subscription] when only terms is satisfied",
       %{conn: conn} do
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert Enum.sort(body["missing"]) == ["profile", "subscription"]
  end

  test "halts 403 with missing=[profile,terms] when only subscription is satisfied",
       %{conn: conn} do
    user = insert(:user)
    insert(:subscription, user: user, status: "trialing")
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["missing"] == ["profile", "terms"]
  end

  test "halts 403 with missing=[vault] when fresh-path profile is set but no vault",
       %{conn: conn} do
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "trialing")
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
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "trialing")
    {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    refute conn.halted
  end

  test "halts 403 with missing=[profile] when terms+subscription ok but profile incomplete",
       %{conn: conn} do
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "trialing")
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["missing"] == ["profile"]
    assert body["next_step"] == "profile"
  end

  test "passes through when fresh-path profile is set AND a vault exists",
       %{conn: conn} do
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "trialing")
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
    user = insert(:user)
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["next_step"] == "agreement"
  end

  test "403 next_step is 'billing' when terms accepted but no subscription", %{conn: conn} do
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["next_step"] == "billing"
  end

  test "403 includes Content-Type application/json", %{conn: conn} do
    user = insert(:user)
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert Plug.Conn.get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
  end
end
