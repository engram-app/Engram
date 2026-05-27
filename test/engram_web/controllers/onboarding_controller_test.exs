defmodule EngramWeb.OnboardingControllerTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts

  setup %{conn: conn} do
    prev_enabled = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)

    Engram.LegalFixtures.insert_version(
      document: "terms_of_service",
      version: "2026-05-15",
      content_hash: "canonical",
      material: true,
      effective_date: nil
    )

    Engram.LegalFixtures.insert_version(
      document: "privacy_policy",
      version: "2026-05-15",
      content_hash: "p",
      material: true,
      effective_date: nil
    )

    Engram.Legal.VersionCache.invalidate_all()
    on_exit(&Engram.Legal.VersionCache.invalidate_all/0)

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_enabled)
    end)

    user = insert(:user)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    grant_api_write!(user)
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  describe "GET /api/onboarding/status" do
    test "returns next_step=agreement for a new user", %{conn: conn} do
      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["enabled"] == true
      assert body["terms_ok"] == false
      assert body["subscription_ok"] == false
      assert body["next_step"] == "agreement"
      assert body["current_tos_version"] == "2026-05-15"
      assert body["current_privacy_version"] == "2026-05-15"
    end

    test "returns next_step=done for fully onboarded user", %{conn: conn, user: user} do
      {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")

      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["next_step"] == "done"
    end

    test "status forwards terms_notice when present", %{conn: conn} do
      Engram.LegalFixtures.insert_version(
        document: "terms_of_service",
        version: "2026-06-01",
        content_hash: "h2",
        material: true,
        effective_date: ~D[2099-01-01]
      )

      Engram.Legal.VersionCache.invalidate_all()

      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["terms_notice"]["version"] == "2026-06-01"
    end

    test "returns enabled=false in self-host mode", %{conn: conn} do
      Application.put_env(:engram, :billing_enabled, false)
      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["enabled"] == false
      assert body["next_step"] == "done"
    end
  end

  describe "POST /api/onboarding/accept-terms" do
    # Seed the canonical current versions these tests accept against. The outer
    # setup already seeded "2026-05-15"; adding "2026-05-19" rows makes that the
    # current version, with content hashes "canonical"/"p".
    setup do
      Engram.LegalFixtures.insert_version(
        document: "terms_of_service",
        version: "2026-05-19",
        content_hash: "canonical",
        material: true,
        effective_date: nil
      )

      Engram.LegalFixtures.insert_version(
        document: "privacy_policy",
        version: "2026-05-19",
        content_hash: "p",
        material: true,
        effective_date: nil
      )

      Engram.Legal.VersionCache.invalidate_all()

      :ok
    end

    defp agreements_for(user) do
      {:ok, rows} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.all(Engram.Onboarding.Agreement)
        end)

      rows
    end

    test "returns 409 when the ToS hash mismatches canonical", %{conn: conn, user: user} do
      conn =
        post(conn, "/api/onboarding/accept-terms", %{
          "tos_version" => "2026-05-19",
          "tos_hash" => "WRONG",
          "privacy_version" => "2026-05-19",
          "privacy_hash" => "p"
        })

      assert json_response(conn, 409)["error"] == "stale"
      assert agreements_for(user) == []
    end

    test "returns 409 when the privacy hash mismatches", %{conn: conn, user: user} do
      conn =
        post(conn, "/api/onboarding/accept-terms", %{
          "tos_version" => "2026-05-19",
          "tos_hash" => "canonical",
          "privacy_version" => "2026-05-19",
          "privacy_hash" => "WRONG"
        })

      assert json_response(conn, 409)["error"] == "stale"
      assert agreements_for(user) == []
    end

    test "returns 201 and records both rows when all match", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 (test)")
        |> post("/api/onboarding/accept-terms", %{
          "tos_version" => "2026-05-19",
          "tos_hash" => "canonical",
          "privacy_version" => "2026-05-19",
          "privacy_hash" => "p"
        })

      body = json_response(conn, 201)
      assert body["version"] == "2026-05-19"

      rows = agreements_for(user)

      tos = Enum.find(rows, &(&1.document == "terms_of_service"))
      privacy = Enum.find(rows, &(&1.document == "privacy_policy"))

      assert tos.content_hash == "canonical"
      assert tos.version == "2026-05-19"
      assert privacy.content_hash == "p"
      assert privacy.version == "2026-05-19"
    end

    test "returns 422 when fields are missing", %{conn: conn} do
      conn = post(conn, "/api/onboarding/accept-terms", %{"tos_version" => "2026-05-19"})
      assert json_response(conn, 422)["error"] == "missing_fields"
    end
  end
end
