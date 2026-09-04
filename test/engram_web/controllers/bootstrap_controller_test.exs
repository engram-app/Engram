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
    # No grant_api_write! — /api/bootstrap is GET-only and RequireApiWriteEnabled
    # never gates GET/HEAD, so granting the paid feature here would wrongly flip
    # the asserted free-tier api_write_enabled default (false) to true.
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

    test "vaults slice under a scoped grant lists only the granted vault", %{conn: conn} do
      user = insert(:user, onboarding_profile: %{})
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      granted = insert(:vault, user: user, slug: "granted", is_default: true)
      _hidden = insert(:vault, user: user, slug: "hidden")

      user = ensure_external_id(user)
      token = Accounts.generate_jwt(user, %{"scope" => "mcp", "vault_ids" => [granted.id]})

      body =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/bootstrap")
        |> json_response(200)

      slugs = body["vaults"]["vaults"] |> Enum.map(& &1["slug"])
      assert slugs == ["granted"]
    end
  end

  describe "GET /api/index-status" do
    test "returns the counters on their own", %{conn: conn} do
      {conn, user} = authed_conn(conn)
      vault = insert(:vault, user: user)

      insert(:note, user: user, vault: vault)
      insert(:note, user: user, vault: vault)

      Engram.Repo.insert!(%Engram.Billing.UserLimitOverride{
        user_id: user.id,
        key: "indexed_notes_cap",
        value: %{"v" => 1},
        reason: "test",
        set_by: "test"
      })

      Engram.Billing.OverrideCache.evict(user.id)

      # The banner this drives is the only thing that keeps a note past the cap
      # returning nothing from reading as broken search. Seeded by /bootstrap,
      # but refetchable so it does not stay frozen at page load.
      assert %{"indexed" => 1, "total" => 2} =
               conn |> get(~p"/api/index-status") |> json_response(200)
    end

    test "requires auth", %{conn: conn} do
      assert conn |> get(~p"/api/index-status") |> json_response(401)
    end
  end
end
