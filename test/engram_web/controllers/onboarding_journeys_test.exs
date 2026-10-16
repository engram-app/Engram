defmodule EngramWeb.OnboardingJourneysTest do
  @moduledoc """
  The three signup journeys in hosted mode (billing on), driven through the
  real HTTP endpoints the SPA calls, in the order it calls them.

  The browser e2e suite runs with billing OFF (no PADDLE_API_KEY in any CI
  stack), so the terms step, the Free start and the connector vault never
  execute there. This is where they are walked end to end.
  """
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts
  alias Engram.Legal.VersionCache
  alias Engram.LegalFixtures

  @terms %{
    "tos_version" => "2026-05-15",
    "tos_hash" => "canonical",
    "privacy_version" => "2026-05-15",
    "privacy_hash" => "p"
  }

  setup %{conn: conn} do
    prev_enabled = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev_enabled) end)

    for {doc, hash} <- [{"terms_of_service", "canonical"}, {"privacy_policy", "p"}] do
      LegalFixtures.insert_version(
        document: doc,
        version: "2026-05-15",
        content_hash: hash,
        material: true,
        effective_date: nil
      )
    end

    VersionCache.invalidate_all()
    on_exit(&VersionCache.invalidate_all/0)

    user = insert(:user, onboarding_profile: %{})
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    lift_api_rps_cap!(user)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{raw_key}"), user: user}
  end

  defp status(conn), do: conn |> get("/api/onboarding/status") |> json_response(200)

  defp accept_terms(conn),
    do: conn |> post("/api/onboarding/accept-terms", @terms) |> json_response(201)

  defp vaults(conn), do: conn |> get("/api/vaults") |> json_response(200) |> Map.fetch!("vaults")

  test "web: terms with heard-from, then the vault step, on Free", %{conn: conn, user: user} do
    assert %{"steps" => ["agreement", "vault"], "next_step" => "agreement"} = status(conn)

    accept_terms(conn)

    assert conn
           |> post("/api/feedback", %{"kind" => "onboarding", "heard_from" => "reddit"})
           |> response(200)

    assert %{"next_step" => "vault", "subscription_ok" => true, "gate_ok" => false} = status(conn)
    assert %DateTime{} = Accounts.get_user!(user.id).free_tier_accepted_at

    conn |> patch("/api/onboarding/profile", %{"uses_obsidian" => false}) |> json_response(201)

    conn
    |> post("/api/vaults/register", %{"name" => "Notes", "client_id" => "web-1"})
    |> json_response(201)

    assert %{"next_step" => "done", "gate_ok" => true} = status(conn)
  end

  test "plugin-first: terms only, then done with no vault so /link can finish", %{conn: conn} do
    conn
    |> patch("/api/onboarding/profile", %{"uses_obsidian" => true, "signup_source" => "plugin"})
    |> json_response(201)

    assert %{"steps" => ["agreement"], "next_step" => "agreement", "gate_ok" => false} =
             status(conn)

    accept_terms(conn)

    assert %{"next_step" => "done", "gate_ok" => true} = status(conn)
    assert vaults(conn) == []
  end

  test "connector: terms only, then done with My Vault ready", %{conn: conn} do
    conn
    |> patch("/api/onboarding/profile", %{"tools" => ["chatgpt"], "tools_prefilled" => true})
    |> json_response(201)

    # Nothing is created before the terms.
    assert vaults(conn) == []
    assert %{"steps" => ["agreement"], "gate_ok" => false} = status(conn)

    accept_terms(conn)

    assert %{"next_step" => "done", "gate_ok" => true} = status(conn)
    assert [%{"name" => "My Vault"}] = vaults(conn)
  end

  test "returning account re-accepting changed terms keeps its plan state", %{
    conn: conn,
    user: user
  } do
    {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-01-01", %{})
    accept_terms(conn)

    assert is_nil(Accounts.get_user!(user.id).free_tier_accepted_at)

    assert %{"next_step" => "billing", "steps" => ["agreement", "billing", "vault"]} =
             status(conn)
  end
end
