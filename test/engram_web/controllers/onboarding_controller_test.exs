defmodule EngramWeb.OnboardingControllerTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts
  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures

  setup %{conn: conn} do
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

    user = insert(:user, onboarding_profile: %{})
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

    test "returns next_step=done for fully onboarded obsidian user", %{conn: conn, user: user} do
      {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")
      {:ok, _} = Engram.Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["next_step"] == "done"
    end

    test "status forwards terms_notice when present", %{conn: conn} do
      LegalFixtures.insert_version(
        document: "terms_of_service",
        version: "2026-06-01",
        content_hash: "h2",
        material: true,
        effective_date: ~D[2099-01-01]
      )

      VersionCache.invalidate_all()

      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["terms_notice"]["version"] == "2026-06-01"
    end

    test "self-host mode reports enabled=true but skips agreement + billing", %{conn: conn} do
      Application.put_env(:engram, :billing_enabled, false)
      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      # Wizard runs (every account onboards), but agreement + billing auto-pass.
      # Fresh user falls through to the :tools step first.
      assert body["enabled"] == true
      assert body["terms_ok"] == true
      assert body["subscription_ok"] == true
      assert body["next_step"] == "tools"
    end
  end

  describe "POST /api/onboarding/accept-terms" do
    # Seed the canonical current versions these tests accept against. The outer
    # setup already seeded "2026-05-15"; adding "2026-05-19" rows makes that the
    # current version, with content hashes "canonical"/"p".
    setup do
      LegalFixtures.insert_version(
        document: "terms_of_service",
        version: "2026-05-19",
        content_hash: "canonical",
        material: true,
        effective_date: nil
      )

      LegalFixtures.insert_version(
        document: "privacy_policy",
        version: "2026-05-19",
        content_hash: "p",
        material: true,
        effective_date: nil
      )

      VersionCache.invalidate_all()

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

  describe "PATCH /api/onboarding/profile" do
    test "returns 201 and persists profile on user", %{conn: conn, user: user} do
      conn =
        patch(conn, "/api/onboarding/profile", %{
          "uses_obsidian" => true,
          "tools" => ["claude", "claude_code"]
        })

      body = json_response(conn, 201)
      assert body["uses_obsidian"] == true
      assert body["tools"] == ["claude", "claude_code"]
      assert is_binary(body["completed_at"])

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      assert reloaded.onboarding_profile["uses_obsidian"] == true
      assert reloaded.onboarding_profile["tools"] == ["claude", "claude_code"]
    end

    test "returns 422 invalid_tool for unknown tool slug", %{conn: conn} do
      conn =
        patch(conn, "/api/onboarding/profile", %{
          "uses_obsidian" => false,
          "tools" => ["telepathy"]
        })

      assert json_response(conn, 422)["error"] == "invalid_tool"
    end

    test "returns 422 empty_tools when tools list is empty", %{conn: conn} do
      conn = patch(conn, "/api/onboarding/profile", %{"uses_obsidian" => false, "tools" => []})
      assert json_response(conn, 422)["error"] == "empty_tools"
    end

    test "returns 422 invalid_uses_obsidian when uses_obsidian is not a boolean", %{conn: conn} do
      conn =
        patch(conn, "/api/onboarding/profile", %{
          "uses_obsidian" => "yes",
          "tools" => ["claude"]
        })

      assert json_response(conn, 422)["error"] == "invalid_uses_obsidian"
    end

    test "accepts a tools-only partial PATCH (wizard's tools step)", %{conn: conn, user: user} do
      conn = patch(conn, "/api/onboarding/profile", %{"tools" => ["claude"]})
      body = json_response(conn, 201)
      assert body["tools"] == ["claude"]
      refute Map.has_key?(body, "uses_obsidian")

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      assert reloaded.onboarding_profile["tools"] == ["claude"]
    end

    test "accepts a uses_obsidian-only partial PATCH (wizard's vault step)",
         %{conn: conn, user: user} do
      conn = patch(conn, "/api/onboarding/profile", %{"uses_obsidian" => true})
      body = json_response(conn, 201)
      assert body["uses_obsidian"] == true
      refute Map.has_key?(body, "tools")

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      assert reloaded.onboarding_profile["uses_obsidian"] == true
    end

    test "two partial PATCHes merge and stamp completed_at", %{conn: conn, user: user} do
      patch(conn, "/api/onboarding/profile", %{"tools" => ["claude"]})
      conn = patch(conn, "/api/onboarding/profile", %{"uses_obsidian" => true})
      body = json_response(conn, 201)
      assert body["tools"] == ["claude"]
      assert body["uses_obsidian"] == true
      assert is_binary(body["completed_at"])

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      assert reloaded.onboarding_profile["completed_at"] |> is_binary()
    end

    test "returns 422 missing_fields when neither uses_obsidian nor tools provided",
         %{conn: conn} do
      conn = patch(conn, "/api/onboarding/profile", %{"unrelated" => "value"})
      assert json_response(conn, 422)["error"] == "missing_fields"
    end
  end

  describe "GET /api/onboarding/status returns profile fields" do
    test "includes profile_complete=false for a new user", %{conn: conn} do
      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["profile_complete"] == false
    end

    test "includes profile_complete=true after PATCH /profile", %{conn: conn} do
      conn1 =
        patch(conn, "/api/onboarding/profile", %{
          "uses_obsidian" => false,
          "tools" => ["web_only"]
        })

      assert conn1.status == 201

      conn2 = get(conn, "/api/onboarding/status")
      body = json_response(conn2, 200)
      assert body["profile_complete"] == true
    end

    test "echoes the saved profile in status payload for personalized cards",
         %{conn: conn} do
      patch(conn, "/api/onboarding/profile", %{
        "uses_obsidian" => true,
        "tools" => ["claude", "cursor"]
      })

      body = json_response(get(conn, "/api/onboarding/status"), 200)
      assert body["profile"]["uses_obsidian"] == true
      assert body["profile"]["tools"] == ["claude", "cursor"]
      assert is_binary(body["profile"]["completed_at"])
    end

    test "omits profile key entirely when no profile has been saved",
         %{conn: conn} do
      body = json_response(get(conn, "/api/onboarding/status"), 200)
      refute Map.has_key?(body, "profile")
    end
  end

  describe "GET /api/onboarding/status payload extensions" do
    test "includes actions list and vault_count", %{conn: conn, user: user} do
      :ok = Engram.Onboarding.record_action(user.id, :first_vault_created)
      {:ok, _vault} = Engram.Vaults.create_vault(user, %{name: "Demo"})

      resp = conn |> get("/api/onboarding/status") |> json_response(200)

      assert "first_vault_created" in resp["actions"]
      assert resp["vault_count"] == 1
    end

    test "actions defaults to [] and vault_count to 0 for new user", %{conn: conn} do
      resp = conn |> get("/api/onboarding/status") |> json_response(200)
      assert resp["actions"] == []
      assert resp["vault_count"] == 0
    end
  end

  describe "POST /api/onboarding/actions" do
    test "records a valid action and is idempotent", %{conn: conn, user: user} do
      assert %{"status" => "ok"} =
               conn
               |> post("/api/onboarding/actions", %{"action" => "tour_offered_skipped"})
               |> json_response(200)

      assert %{"status" => "ok"} =
               conn
               |> post("/api/onboarding/actions", %{"action" => "tour_offered_skipped"})
               |> json_response(200)

      assert ["tour_offered_skipped"] = Engram.Onboarding.list_actions(user.id)
    end

    test "rejects unknown action with 422", %{conn: conn} do
      assert %{"error" => _} =
               conn
               |> post("/api/onboarding/actions", %{"action" => "bogus"})
               |> json_response(422)
    end

    test "401 when unauthenticated" do
      conn = Phoenix.ConnTest.build_conn()

      assert conn
             |> post("/api/onboarding/actions", %{"action" => "tour_completed"})
             |> response(401)
    end

    test "multi-tenant — cannot insert for another user", %{conn: conn, user: user} do
      other_user = insert(:user)

      conn
      |> post("/api/onboarding/actions", %{"action" => "tour_completed"})
      |> json_response(200)

      assert ["tour_completed"] = Engram.Onboarding.list_actions(user.id)
      assert [] = Engram.Onboarding.list_actions(other_user.id)
    end
  end
end
