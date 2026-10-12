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

  test "429 once a user passes the hourly budget", %{conn: conn} do
    for _ <- 1..20 do
      assert conn
             |> post("/api/feedback", %{"kind" => "general", "message" => "hi"})
             |> json_response(200)
    end

    conn = post(conn, "/api/feedback", %{"kind" => "general", "message" => "hi"})
    assert json_response(conn, 429) == %{"error" => "rate_limited"}
  end

  test "stamps the request's user agent onto general feedback", %{conn: conn} do
    prior_key = Application.get_env(:engram, :posthog_key)
    prior_host = Application.get_env(:engram, :posthog_host)

    on_exit(fn ->
      Application.put_env(:engram, :posthog_key, prior_key)
      Application.put_env(:engram, :posthog_host, prior_host)
    end)

    bypass = Bypass.open()
    parent = self()

    Bypass.stub(bypass, "POST", "/capture/", fn c ->
      {:ok, body, c} = Plug.Conn.read_body(c)
      send(parent, {:posthog, Jason.decode!(body)})
      Plug.Conn.resp(c, 200, "1")
    end)

    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")

    conn
    |> put_req_header("user-agent", "TestBrowser/1.0")
    |> post("/api/feedback", %{"kind" => "general", "message" => "hi", "user_agent" => "spoof"})
    |> json_response(200)

    assert_receive {:posthog, %{"properties" => %{"user_agent" => "TestBrowser/1.0"}}}, 1_000
  end

  test "401 without auth" do
    conn = post(build_conn(), "/api/feedback", %{"kind" => "general", "message" => "hi"})
    assert conn.status == 401
  end
end
