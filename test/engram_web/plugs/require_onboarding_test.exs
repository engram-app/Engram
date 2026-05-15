defmodule EngramWeb.Plugs.RequireOnboardingTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Onboarding
  alias EngramWeb.Plugs.RequireOnboarding

  setup do
    prev_enabled = Application.get_env(:engram, :billing_enabled)
    prev_version = Application.get_env(:engram, :current_tos_version)
    Application.put_env(:engram, :billing_enabled, true)
    Application.put_env(:engram, :current_tos_version, "2026-05-15")

    on_exit(fn ->
      Application.put_env(:engram, :billing_enabled, prev_enabled)
      Application.put_env(:engram, :current_tos_version, prev_version)
    end)

    :ok
  end

  test "passes through when billing is disabled (self-host)", %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, false)
    user = insert(:user)
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    refute conn.halted
  end

  test "halts 403 with missing=[terms,subscription] when both gates fail", %{conn: conn} do
    user = insert(:user)
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["error"] == "onboarding_required"
    assert Enum.sort(body["missing"]) == ["subscription", "terms"]
  end

  test "halts 403 with missing=[subscription] when only subscription is missing", %{conn: conn} do
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["missing"] == ["subscription"]
  end

  test "halts 403 with missing=[terms] when only terms is missing", %{conn: conn} do
    user = insert(:user)
    insert(:subscription, user: user, status: "trialing")
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["missing"] == ["terms"]
  end

  test "passes through when both gates are satisfied", %{conn: conn} do
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "trialing")
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    refute conn.halted
  end
end
