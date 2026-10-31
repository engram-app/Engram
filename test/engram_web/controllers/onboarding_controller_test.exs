defmodule EngramWeb.OnboardingControllerTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts
  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures
  alias Engram.Test.LogCapture
  alias Engram.Vaults

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
    lift_api_rps_cap!(user)
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

    test "returns next_step=done for fully onboarded obsidian user with vault",
         %{conn: conn, user: user} do
      {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "active")
      {:ok, _} = Engram.Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      insert(:vault, user: user)

      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["next_step"] == "done"
    end

    test "status forwards legal_notices", %{conn: conn, user: user} do
      # A change is only news to an account that accepted an earlier version.
      {:ok, _} =
        Engram.Onboarding.accept_terms(user, "2026-05-15", "canonical", "2026-05-15", "p", %{})

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

      assert [%{"document" => "terms_of_service", "version" => "2026-06-01", "material" => true}] =
               body["legal_notices"]
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
      assert body["next_step"] == "vault"
    end
  end

  describe "POST /api/onboarding/accept-terms" do
    # The Free stamp found no row to take (a purge racing the accept): the
    # whole acceptance rolled back, and there is no user to accept for.
    test "404 when the Free stamp finds no user row", %{conn: conn} do
      Engram.FreeStampBlock.block!()

      conn =
        post(conn, "/api/onboarding/accept-terms", %{
          "tos_version" => "2026-05-19",
          "tos_hash" => "canonical",
          "privacy_version" => "2026-05-19",
          "privacy_hash" => "p"
        })

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

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

    # Third review #10: the acceptance records the CLIENT's IP (CF-Connecting-IP
    # behind the edge), not the load balancer's.
    test "records the client IP from CF-Connecting-IP when trusted", %{conn: conn, user: user} do
      previous = Application.get_env(:engram, :trust_cf_connecting_ip)
      Application.put_env(:engram, :trust_cf_connecting_ip, true)
      on_exit(fn -> Application.put_env(:engram, :trust_cf_connecting_ip, previous) end)

      conn
      |> put_req_header("cf-connecting-ip", "203.0.113.42")
      |> post("/api/onboarding/accept-terms", %{
        "tos_version" => "2026-05-19",
        "tos_hash" => "canonical",
        "privacy_version" => "2026-05-19",
        "privacy_hash" => "p"
      })
      |> json_response(201)

      assert Enum.all?(agreements_for(user), &(to_string(&1.ip_address) =~ "203.0.113.42"))
    end

    # A browser on an older bundle cannot render a version published after it
    # was built. It accepts the newest one it can render, which is binding as
    # long as it is not below the required floor.
    test "accepts a known version older than the current one", %{conn: conn, user: user} do
      LegalFixtures.insert_version(
        document: "privacy_policy",
        version: "2026-10-14",
        content_hash: "p-new",
        material: false,
        effective_date: nil
      )

      VersionCache.invalidate_all()

      conn =
        post(conn, "/api/onboarding/accept-terms", %{
          "tos_version" => "2026-05-19",
          "tos_hash" => "canonical",
          "privacy_version" => "2026-05-19",
          "privacy_hash" => "p"
        })

      assert json_response(conn, 201)
      privacy = Enum.find(agreements_for(user), &(&1.document == "privacy_policy"))
      assert privacy.version == "2026-05-19"
    end

    test "returns 409 for a known version below the required floor", %{conn: conn, user: user} do
      # Terms floor is 2026-05-19; 2026-05-15 is a real version with this hash.
      conn =
        post(conn, "/api/onboarding/accept-terms", %{
          "tos_version" => "2026-05-15",
          "tos_hash" => "canonical",
          "privacy_version" => "2026-05-19",
          "privacy_hash" => "p"
        })

      assert json_response(conn, 409)["error"] == "stale"
      assert agreements_for(user) == []
    end

    test "returns 409 for an unknown version", %{conn: conn, user: user} do
      conn =
        post(conn, "/api/onboarding/accept-terms", %{
          "tos_version" => "2026-05-19",
          "tos_hash" => "canonical",
          "privacy_version" => "2099-01-01",
          "privacy_hash" => "p"
        })

      assert json_response(conn, 409)["error"] == "stale"
      assert agreements_for(user) == []
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

    test "accepts signup attribution on its own", %{conn: conn, user: user} do
      conn =
        patch(conn, "/api/onboarding/profile", %{
          "attribution" => %{"utm_source" => "reddit", "referrer_domain" => "reddit.com"}
        })

      assert json_response(conn, 201)["attribution"] == %{
               "utm_source" => "reddit",
               "referrer_domain" => "reddit.com"
             }

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      assert reloaded.onboarding_profile["attribution"]["utm_source"] == "reddit"
    end

    test "returns 422 invalid_attribution for unusable attribution", %{conn: conn} do
      conn = patch(conn, "/api/onboarding/profile", %{"attribution" => %{"utm_term" => "x"}})
      assert json_response(conn, 422)["error"] == "invalid_attribution"
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
      {:ok, _vault, _} = Vaults.register_vault(user, "Demo", Ecto.UUID.generate())

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

  describe "POST /api/onboarding/accept_free_tier" do
    test "sets free_tier_accepted_at and returns next step", %{conn: conn, user: user} do
      assert is_nil(user.free_tier_accepted_at)

      conn = post(conn, ~p"/api/onboarding/accept_free_tier")
      body = json_response(conn, 200)
      assert Map.has_key?(body, "next_step")

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      assert reloaded.free_tier_accepted_at != nil
    end

    test "is idempotent", %{conn: conn} do
      post(conn, ~p"/api/onboarding/accept_free_tier")
      conn2 = post(conn, ~p"/api/onboarding/accept_free_tier")
      assert json_response(conn2, 200)
    end

    test "401 when unauthenticated" do
      conn = Phoenix.ConnTest.build_conn()

      assert conn
             |> post(~p"/api/onboarding/accept_free_tier")
             |> response(401)
    end

    # The user row went away between auth and the stamp (a purge racing the
    # click): nothing took the stamp. Driven through the controller directly,
    # since the auth plug would 401 a missing user before reaching it.
    test "404 when the user row is gone" do
      ghost = build(:user, id: Ecto.UUID.generate(), free_tier_accepted_at: nil)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:current_user, ghost)
        |> Phoenix.Controller.put_format("json")
        |> EngramWeb.OnboardingController.call(
          EngramWeb.OnboardingController.init(:accept_free_tier)
        )

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  # The wizard's progress is otherwise invisible in prod: success responses are
  # not request-logged, so a signup refused on /link and then silent could have
  # finished the wizard or left, and nothing tells the two apart.
  describe "wizard step logging" do
    import ExUnit.CaptureLog

    setup do
      # config/test.exs sets the logger to :warning; these lines are :info.
      # Safe globally: this module is async: false.
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)
    end

    test "logs terms acceptance", %{conn: conn} do
      log =
        capture_log([level: :info], fn ->
          post(conn, "/api/onboarding/accept-terms", %{
            "tos_version" => "2026-05-15",
            "tos_hash" => "canonical",
            "privacy_version" => "2026-05-15",
            "privacy_hash" => "p"
          })
        end)

      assert log =~ "onboarding step completed: terms"
    end

    test "logs free-tier acceptance", %{conn: conn} do
      log =
        capture_log([level: :info], fn -> post(conn, ~p"/api/onboarding/accept_free_tier") end)

      assert log =~ "onboarding step completed: free_tier"
    end

    test "logs a profile save with the fields it set", %{conn: conn} do
      log =
        capture_log([level: :info], fn ->
          patch(conn, "/api/onboarding/profile", %{"uses_obsidian" => true})
        end)

      assert log =~ "onboarding step completed: profile"
      assert log =~ "uses_obsidian"
    end

    # A refusal line with nothing after it could be a stuck user or one who
    # finished. This is the line after it, keyed the same way (user_id,
    # category lifecycle) so one LogQL query joins the two.
    test "logs the gate opening on the step that opens it", %{conn: conn, user: user} do
      accept_terms!(conn)

      {_, events} =
        LogCapture.with_events(fn ->
          patch(conn, "/api/onboarding/profile", %{"uses_obsidian" => true})
        end)

      event = Enum.find(events, &gate_opened?/1)
      assert event, "no onboarding gate opened line"
      assert event.level == :info
      assert event.meta[:user_id] == user.id
      assert event.meta[:category] == :lifecycle
      assert event.meta[:loki_ship] == true
      assert event.meta[:trigger] == "profile"
    end

    # Only the closed-to-open change logs: a step re-posted by a user whose
    # gate is already open (a connector PATCHing tools_prefilled, a privacy
    # notice dismissed) would otherwise count as a second opening.
    test "does not log the gate opening for a user it is already open for", %{conn: conn} do
      accept_terms!(conn)
      patch(conn, "/api/onboarding/profile", %{"uses_obsidian" => true})

      {_, events} =
        LogCapture.with_events(fn ->
          patch(conn, "/api/onboarding/profile", %{"tools" => ["claude"]})
        end)

      refute Enum.find(events, &gate_opened?/1)
    end

    # accept-terms also provisions a connector signup's vault: one opening,
    # one line.
    test "a connector signup's terms step logs one opening", %{conn: conn, user: user} do
      {:ok, _} =
        Engram.Onboarding.set_profile(user, %{tools: ["chatgpt"], tools_prefilled: true})

      {_, events} = LogCapture.with_events(fn -> accept_terms!(conn) end)

      assert [event] = Enum.filter(events, &gate_opened?/1)
      assert event.meta[:trigger] == "terms"
    end

    test "does not log the gate opening while steps remain", %{conn: conn} do
      {_, events} = LogCapture.with_events(fn -> accept_terms!(conn) end)

      refute Enum.find(events, &gate_opened?/1)
    end

    # The web path: terms and profile done, the first vault is the last step.
    test "logs the gate opening when the first vault opens it", %{conn: conn, user: user} do
      accept_terms!(conn)
      patch(conn, "/api/onboarding/profile", %{"uses_obsidian" => false})

      {_, events} =
        LogCapture.with_events(fn ->
          {:ok, _, :created} = Vaults.register_vault(user, "Main", Ecto.UUID.generate())
        end)

      event = Enum.find(events, &gate_opened?/1)
      assert event, "no onboarding gate opened line"
      assert event.meta[:trigger] == "vault"
    end

    test "logs vaults_left when a vault is deleted", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
      {:ok, a, _} = Vaults.register_vault(user, "A", Ecto.UUID.generate())
      {:ok, _b, _} = Vaults.register_vault(user, "B", Ecto.UUID.generate())

      {_, events} =
        LogCapture.with_events(fn -> Vaults.delete_vault(user, a.id) end)

      event =
        Enum.find(events, fn
          %{msg: {:string, s}} -> IO.iodata_to_binary(s) == "vault deleted"
          _ -> false
        end)

      assert event, "no vault deleted line"
      assert event.meta[:vaults_left] == 1
    end

    defp accept_terms!(conn) do
      post(conn, "/api/onboarding/accept-terms", %{
        "tos_version" => "2026-05-15",
        "tos_hash" => "canonical",
        "privacy_version" => "2026-05-15",
        "privacy_hash" => "p"
      })
    end

    defp gate_opened?(%{msg: {:string, s}}),
      do: IO.iodata_to_binary(s) == "onboarding gate opened"

    defp gate_opened?(_), do: false

    test "does not log a rejected profile save", %{conn: conn} do
      log =
        capture_log([level: :info], fn ->
          patch(conn, "/api/onboarding/profile", %{"tools" => []})
        end)

      refute log =~ "onboarding step completed"
    end
  end
end
