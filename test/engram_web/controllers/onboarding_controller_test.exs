defmodule EngramWeb.OnboardingControllerTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts

  setup %{conn: conn} do
    prev_enabled = Application.get_env(:engram, :billing_enabled)
    prev_version = Application.get_env(:engram, :current_tos_version)
    prev_min = Application.get_env(:engram, :min_required_tos_version)
    Application.put_env(:engram, :billing_enabled, true)
    Application.put_env(:engram, :current_tos_version, "2026-05-15")
    # min_required tracks current here so accepting "2026-05-15" satisfies the gate.
    Application.put_env(:engram, :min_required_tos_version, "2026-05-15")

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_enabled)
      Application.put_env(:engram, :current_tos_version, prev_version)
      Application.put_env(:engram, :min_required_tos_version, prev_min)
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

    test "returns enabled=false in self-host mode", %{conn: conn} do
      Application.put_env(:engram, :billing_enabled, false)
      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["enabled"] == false
      assert body["next_step"] == "done"
    end
  end

  describe "POST /api/onboarding/accept-terms" do
    # Pin all four canonical config values these tests assert against. test.exs
    # pins only current_tos_version, so set the rest here with on_exit restore.
    setup do
      prev = %{
        tos_version: Application.get_env(:engram, :current_tos_version),
        tos_hash: Application.get_env(:engram, :current_tos_hash),
        privacy_version: Application.get_env(:engram, :current_privacy_version),
        privacy_hash: Application.get_env(:engram, :current_privacy_hash)
      }

      Application.put_env(:engram, :current_tos_version, "2026-05-19")
      Application.put_env(:engram, :current_tos_hash, "canonical")
      Application.put_env(:engram, :current_privacy_version, "2026-05-19")
      Application.put_env(:engram, :current_privacy_hash, "p")

      on_exit(fn ->
        Application.put_env(:engram, :current_tos_version, prev.tos_version)
        Application.put_env(:engram, :current_tos_hash, prev.tos_hash)
        Application.put_env(:engram, :current_privacy_version, prev.privacy_version)
        Application.put_env(:engram, :current_privacy_hash, prev.privacy_hash)
      end)

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
