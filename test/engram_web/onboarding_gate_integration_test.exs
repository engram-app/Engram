defmodule EngramWeb.OnboardingGateIntegrationTest do
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

    user = insert_user()
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    grant_api_write!(user)
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  test "GET /api/folders returns 403 onboarding_required for new user", %{conn: conn} do
    conn = get(conn, "/api/folders")
    body = json_response(conn, 403)
    assert body["error"] == "onboarding_required"
    assert "subscription" in body["missing"]
    assert "terms" in body["missing"]
  end

  test "GET /api/folders returns 200 after onboarding completes", %{conn: conn, user: user} do
    {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "active")
    # Setup already inserts a vault — pair with uses_obsidian=false so the
    # new vault gate sees has_vault=true and lets the request through.
    {:ok, _} = Engram.Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})

    conn = get(conn, "/api/folders")
    assert conn.status == 200
  end

  test "GET /api/folders returns 200 in self-host mode", %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, false)
    conn = get(conn, "/api/folders")
    assert conn.status == 200
  end

  # Coverage matrix: prove RequireOnboarding halts every request shape on
  # the vault pipeline (verbs, splat routes, MCP scope). Without these,
  # a future route added to the vault scope could silently bypass the
  # gate if the test only covered GET /api/folders.

  test "POST /api/notes is gated (mutation halts BEFORE write)", %{conn: conn} do
    body = %{path: "Test/note.md", content: "x", mtime: 1_700_000_000.0}
    resp = post(conn, "/api/notes", body)
    assert json_response(resp, 403)["error"] == "onboarding_required"
    refute Engram.Repo.exists?(Engram.Notes.Note, skip_tenant_check: true)
  end

  test "DELETE /api/notes/*path (splat route) is gated", %{conn: conn} do
    resp = delete(conn, "/api/notes/Some/Path.md")
    assert json_response(resp, 403)["error"] == "onboarding_required"
  end

  test "POST /api/search is gated", %{conn: conn} do
    resp = post(conn, "/api/search", %{query: "anything"})
    assert json_response(resp, 403)["error"] == "onboarding_required"
  end

  test "POST /api/mcp (nested scope) is gated", %{conn: conn} do
    resp =
      post(conn, "/api/mcp", %{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}})

    assert json_response(resp, 403)["error"] == "onboarding_required"
  end

  test "self-host mode lets POST /api/notes through (gate is no-op)", %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, false)
    body = %{path: "Test/note.md", content: "# Hi", mtime: 1_700_000_000.0}
    resp = post(conn, "/api/notes", body)
    assert resp.status in [200, 201]
  end

  test "suspended user gets 402 from RequireActiveSubscription on vault routes",
       %{conn: conn, user: user} do
    # Pass onboarding fully: terms accepted, Free tier accepted (counts as
    # subscription_ok), profile complete, vault present (setup already added one).
    {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, user} = Engram.Onboarding.accept_free_tier(user)
    {:ok, _} = Engram.Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})

    # Now suspend the user — RequireOnboarding still passes (Free accepted),
    # but RequireActiveSubscription should halt with 402 account_suspended.
    {:ok, _user} =
      user
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now())
      |> Engram.Repo.update()

    resp = get(conn, "/api/notes/changes")
    body = json_response(resp, 402)
    assert body["error"] == "limit_exceeded"
    assert body["reason"] == "account_suspended"
  end
end
