defmodule EngramWeb.FeedbackControllerTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts

  setup %{conn: conn} do
    # Not onboarded on purpose: the survey is answered mid-wizard, so the
    # route must sit outside RequireOnboarding.
    user = insert(:user, onboarding_profile: %{})
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  test "200 on a valid submission before onboarding is complete", %{conn: conn, user: user} do
    conn = post(conn, "/api/feedback", %{"kind" => "onboarding", "heard_from" => "youtube"})
    assert json_response(conn, 200) == %{"status" => "ok"}

    reloaded = Engram.Repo.get!(Accounts.User, user.id, skip_tenant_check: true)
    assert reloaded.onboarding_profile["heard_from"] == "youtube"
  end

  test "422 with the error code on invalid input", %{conn: conn} do
    conn = post(conn, "/api/feedback", %{"kind" => "cancel", "reason" => "meh"})
    assert json_response(conn, 422)["error"] == "invalid_reason"
  end

  test "401 without auth" do
    conn = post(build_conn(), "/api/feedback", %{"kind" => "general", "message" => "hi"})
    assert conn.status == 401
  end
end
