defmodule EngramWeb.BootstrapControllerTest do
  # async: false — flips the global :billing_enabled app env (toggles whether
  # the billing slice is present) and reads through the process-global
  # EntitlementCache. Matches the other billing_enabled-flipping suites.
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts
  alias Engram.Billing.EntitlementCache
  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures

  setup do
    on_exit(fn -> EntitlementCache.evict_all() end)
    :ok
  end

  defp authed_conn(conn) do
    user = insert(:user, onboarding_profile: %{})
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    grant_api_write!(user)
    {put_req_header(conn, "authorization", "Bearer #{raw_key}"), user}
  end

  describe "GET /api/bootstrap (billing enabled)" do
    setup %{conn: conn} do
      prev = Application.get_env(:engram, :billing_enabled)
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
      on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev) end)

      {conn, user} = authed_conn(conn)
      {:ok, conn: conn, user: user}
    end

    test "returns onboarding, capabilities, vaults, and billing in one payload", %{conn: conn} do
      body = conn |> get("/api/bootstrap") |> json_response(200)

      # Onboarding slice mirrors GET /api/onboarding/status for a fresh user.
      assert body["onboarding"]["enabled"] == true
      assert body["onboarding"]["next_step"] == "agreement"

      # Capabilities slice — free-tier matrix.
      assert body["capabilities"]["tier"] == "free"
      assert body["capabilities"]["limits"]["notes_cap"] == 10_000
      assert body["capabilities"]["limits"]["api_write_enabled"] == false

      # Vaults slice — empty for a brand-new user.
      assert body["vaults"]["vaults"] == []

      # Billing slice present because billing is enabled.
      assert body["billing"]["tier"] == "free"
      assert body["billing"]["active"] == false
    end

    test "capabilities reflect a paid subscription", %{conn: conn, user: user} do
      insert(:subscription, user: user, tier: "pro", status: "active")

      body = conn |> get("/api/bootstrap") |> json_response(200)

      assert body["capabilities"]["tier"] == "pro"
      assert body["capabilities"]["limits"]["notes_cap"] == nil
      assert body["billing"]["tier"] == "pro"
    end

    test "returns 401 without auth" do
      assert build_conn() |> get("/api/bootstrap") |> json_response(401)
    end
  end

  describe "GET /api/bootstrap (billing disabled / self-host)" do
    setup %{conn: conn} do
      prev = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, false)
      on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev) end)

      {conn, user} = authed_conn(conn)
      {:ok, conn: conn, user: user}
    end

    test "omits the billing slice but still returns capabilities", %{conn: conn} do
      body = conn |> get("/api/bootstrap") |> json_response(200)

      refute Map.has_key?(body, "billing")
      assert body["capabilities"]["tier"] == "free"
      assert is_map(body["capabilities"]["limits"])
      assert body["onboarding"]["enabled"] == true
    end
  end
end
