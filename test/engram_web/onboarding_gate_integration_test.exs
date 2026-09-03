defmodule EngramWeb.OnboardingGateIntegrationTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts
  alias Engram.Auth.DeviceFlow
  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.GateCache
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

    user = insert_user()
    vault = insert(:vault, user: user, is_default: true)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    grant_api_write!(user)

    # Two credentials on purpose. The vault-pipeline tests below keep the API
    # key — proving the gate halts an API key is part of what they assert.
    # `/auth/device/authorize` sits behind `RequireSession`, which halts an API
    # key in the router pipeline before `RequireOnboarding` (a controller plug)
    # runs, so the three device tests need a session to reach the gate at all.
    # `Onboarding.gate/2` keys on `:current_user` only, so the verdict is
    # identical either way.
    user = ensure_external_id(user)
    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)

    {:ok,
     conn: put_req_header(conn, "authorization", "Bearer #{raw_key}"),
     session_conn: put_req_header(conn, "authorization", "Bearer #{token}"),
     user: user,
     vault: vault}
  end

  test "GET /api/folders returns 403 onboarding_required for new user", %{conn: conn} do
    conn = get(conn, "/api/folders")
    body = json_response(conn, 403)
    assert body["error"] == "onboarding_required"
    assert "subscription" in body["missing"]
    assert "terms" in body["missing"]
  end

  test "GET /api/folders returns 200 after onboarding completes", %{conn: conn, user: user} do
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "active")
    # Setup already inserts a vault — pair with uses_obsidian=false so the
    # new vault gate sees has_vault=true and lets the request through.
    {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})

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

  # The device-link flow lives on the user-scoped pipeline (it must stay
  # reachable so the wizard can create a first vault), so it does NOT inherit
  # RequireOnboarding from the vault pipeline — it declares the plug itself.
  # Without this the plugin links happily and only discovers the problem as a
  # silent channel-join refusal.
  test "POST /api/auth/device/authorize is gated", %{session_conn: conn, user: user} do
    vault = insert(:vault, user: user)
    {:ok, auth} = DeviceFlow.start_device_flow("client_1")

    resp =
      post(conn, "/api/auth/device/authorize", %{
        user_code: auth.user_code,
        vault_id: vault.id
      })

    assert json_response(resp, 403)["error"] == "onboarding_required"

    assert {:error, :authorization_pending} =
             DeviceFlow.exchange_device_code(auth.device_code)
  end

  test "POST /api/auth/device/authorize succeeds once onboarding completes", %{
    session_conn: conn,
    user: user
  } do
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, _} = Onboarding.accept_free_tier(user)
    {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

    vault = insert(:vault, user: user)
    {:ok, auth} = DeviceFlow.start_device_flow("client_1")

    resp =
      post(conn, "/api/auth/device/authorize", %{
        user_code: auth.user_code,
        vault_id: vault.id
      })

    assert json_response(resp, 200)["ok"] == true
  end

  # Catch-22: `vault_id: "new"` is the endpoint that CREATES the first vault,
  # so gating it on "you must already have a vault" makes it permanently
  # unreachable for the exact user who needs it. `Vaults.delete_vault/2`
  # evicts the gate cache on last-vault deletion specifically because it
  # "can flip the onboarding gate back to failing" — so zero-vault users are
  # an anticipated state, not a hypothetical.
  test "device authorize with vault_id=new works for a user with NO vault", %{
    session_conn: conn,
    user: user,
    vault: vault
  } do
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, _} = Onboarding.accept_free_tier(user)
    # uses_obsidian=false is what makes the vault gate apply at all.
    {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})
    # The real path into this state: delete_vault/2 evicts the gate cache
    # itself, precisely because the last deletion can flip the gate.
    {:ok, _} = Vaults.delete_vault(user, vault.id)
    GateCache.evict_all()

    refute Vaults.has_vault?(user)
    {:ok, auth} = DeviceFlow.start_device_flow("client_1")

    resp =
      post(conn, "/api/auth/device/authorize", %{
        user_code: auth.user_code,
        vault_id: "new",
        vault_name: "First Vault"
      })

    assert json_response(resp, 200)["ok"] == true
  end

  # The relaxed verdict must never reach the cache: the channels read the same
  # cache, and a cached PASS earned by skipping the vault rule would hand the
  # full sync path to a user the strict rule rejects.
  test "skip_vault passes WITHOUT caching the verdict" do
    user = insert_user()
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, _} = Onboarding.accept_free_tier(user)
    {:ok, user} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})
    GateCache.evict_all()

    refute Vaults.has_vault?(user)

    # `user` here is deliberately the struct from BEFORE accept_free_tier —
    # gate/2 must re-read the row rather than trust it (socket-frozen structs).
    assert :ok = Onboarding.gate(user, skip_vault: true)
    refute GateCache.passed?(user.id)
    assert {:error, ["vault"], _} = Onboarding.gate(user)
  end

  test "suspended user gets 402 from RequireActiveSubscription on vault routes",
       %{conn: conn, user: user} do
    # Pass onboarding fully: terms accepted, Free tier accepted (counts as
    # subscription_ok), profile complete, vault present (setup already added one).
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    {:ok, user} = Onboarding.accept_free_tier(user)
    {:ok, _} = Onboarding.set_profile(user, %{uses_obsidian: false, tools: ["claude"]})

    # Now suspend the user — RequireOnboarding still passes (Free accepted),
    # but RequireActiveSubscription should halt with 402 account_suspended.
    {:ok, _user} =
      user
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now())
      |> Engram.Repo.update()

    resp = get(conn, "/api/sync/manifest")
    body = json_response(resp, 402)
    assert body["error"] == "limit_exceeded"
    assert body["reason"] == "account_suspended"
  end
end
