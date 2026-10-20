defmodule EngramWeb.AnalyticsControllerTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Observability.PostHog

  setup %{conn: conn} do
    EngramWeb.RateLimiter.reset_buckets!()
    bypass = Bypass.open()

    prior =
      {Application.get_env(:engram, :posthog_key), Application.get_env(:engram, :posthog_host)}

    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      {key, host} = prior
      Application.put_env(:engram, :posthog_key, key)
      Application.put_env(:engram, :posthog_host, host)
    end)

    parent = self()

    Bypass.stub(bypass, "POST", "/capture/", fn c ->
      {:ok, body, c} = Plug.Conn.read_body(c)
      send(parent, {:posthog_body, Jason.decode!(body)})
      Plug.Conn.resp(c, 200, "1")
    end)

    user = insert(:user)
    %{conn: authenticate(conn, user), user: user}
  end

  defp summary_event(name) do
    receive do
      {:posthog_body, %{"event" => ^name} = body} -> body
      {:posthog_body, _} -> summary_event(name)
    after
      1_000 -> nil
    end
  end

  test "a planned summary is first_sync_planned with bounded counts", %{conn: conn, user: user} do
    conn =
      post(conn, "/api/analytics/sync-summary", %{
        "phase" => "planned",
        "notes" => 1200,
        "attachments" => 30,
        "folders" => 99_999_999_999,
        "choice" => "merge",
        "platform" => "desktop",
        "path" => "Secret/Note.md"
      })

    assert response(conn, 204)
    body = summary_event("first_sync_planned")
    assert body["distinct_id"] == PostHog.analytics_id(user.email)

    assert Map.take(body["properties"], ~w(notes attachments folders choice platform path)) == %{
             "notes" => 1200,
             "attachments" => 30,
             "folders" => 10_000_000,
             "choice" => "merge",
             "platform" => "desktop"
           }
  end

  test "a finished summary is first_sync_finished with an outcome", %{conn: conn} do
    conn =
      post(conn, "/api/analytics/sync-summary", %{
        "phase" => "finished",
        "total" => 100,
        "failed" => 3,
        "skipped" => 2,
        "duration_ms" => 4_500
      })

    assert response(conn, 204)
    props = summary_event("first_sync_finished")["properties"]
    assert props["total"] == 100
    assert props["failed"] == 3
    assert props["skipped"] == 2
    assert props["duration_ms"] == 4_500
    assert props["outcome"] == "partial"
    refute Map.has_key?(props, "platform")
  end

  test "unknown phases, enums and non-integer counts are refused or dropped", %{conn: conn} do
    assert conn
           |> post("/api/analytics/sync-summary", %{"phase" => "other"})
           |> json_response(422)

    conn =
      post(conn, "/api/analytics/sync-summary", %{
        "phase" => "planned",
        "notes" => "lots",
        "choice" => "rm -rf",
        "platform" => "toaster"
      })

    assert response(conn, 204)
    props = summary_event("first_sync_planned")["properties"]
    refute Map.has_key?(props, "notes")
    refute Map.has_key?(props, "choice")
    refute Map.has_key?(props, "platform")
  end

  test "a retry loop sends one event per phase per hour", %{conn: conn} do
    for _ <- 1..3, do: post(conn, "/api/analytics/sync-summary", %{"phase" => "finished"})

    assert summary_event("first_sync_finished")
    assert summary_event("first_sync_finished") == nil
  end
end
