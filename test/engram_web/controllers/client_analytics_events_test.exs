defmodule EngramWeb.ClientAnalyticsEventsTest do
  @moduledoc """
  `POST /api/analytics/events`: the web app's funnel events (paywall, checkout,
  onboarding steps, connects) into our own event log, so the insights funnel
  sees them. Recorded only: never forwarded to PostHog, which the browser
  already sends them to. Global app env, so not async.
  """
  use EngramWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Engram.Analytics.Event
  alias Engram.Analytics.EventLog
  alias Engram.Repo

  @vault "12dc6735-52f2-4ce4-9117-91f0ce2389a7"

  setup %{conn: conn} do
    EngramWeb.RateLimiter.reset_buckets!()
    bypass = Bypass.open()

    prior =
      {Application.get_env(:engram, :posthog_key), Application.get_env(:engram, :posthog_host),
       Application.get_env(:engram, :analytics_event_log)}

    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")
    Application.put_env(:engram, :analytics_event_log, true)

    on_exit(fn ->
      {key, host, log} = prior
      Application.put_env(:engram, :posthog_key, key)
      Application.put_env(:engram, :posthog_host, host)
      Application.put_env(:engram, :analytics_event_log, log)
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

  defp stored do
    :ok = EventLog.flush()
    Repo.all(from(e in Event, where: e.event != "surface_active", order_by: e.inserted_at))
  end

  defp send_events(conn, events), do: post(conn, "/api/analytics/events", %{"events" => events})

  test "stores the web app's funnel events, and never forwards them to PostHog", %{
    conn: conn,
    user: user
  } do
    conn =
      send_events(conn, [
        %{"event" => "paywall_shown", "props" => %{"limit_key" => "notes_cap_exceeded"}},
        %{
          "event" => "checkout_opened",
          "props" => %{"tier" => "pro", "cadence" => "monthly", "source" => "paywall"}
        },
        %{
          "event" => "onboarding_step_completed",
          "props" => %{"step" => "vault", "vault_id" => @vault, "duration_ms" => 1200}
        },
        %{"event" => "onboarding_blocked", "props" => %{"missing" => ["terms", "vault"]}},
        %{"event" => "plugin_listing_opened"}
      ])

    assert response(conn, 204)

    rows = stored()
    assert Enum.all?(rows, &(&1.user_id == user.id))

    assert Enum.map(rows, & &1.event) == ~w(paywall_shown checkout_opened
             onboarding_step_completed onboarding_blocked plugin_listing_opened)

    assert hd(rows).props == %{"limit_key" => "notes_cap_exceeded"}
    assert Enum.at(rows, 3).props == %{"missing" => ["terms", "vault"]}
    refute_receive {:posthog_body, %{"event" => "paywall_shown"}}, 300
  end

  test "stores browser language events, and refuses a language that is not a tag", %{conn: conn} do
    conn =
      send_events(conn, [
        %{
          "event" => "browser_languages_unsupported",
          "props" => %{"languages" => ["ar", "he-IL"]}
        },
        %{
          "event" => "browser_translation_detected",
          "props" => %{"to" => "ar", "app_locale" => "en"}
        },
        %{"event" => "browser_translation_detected", "props" => %{"to" => "my secret note"}},
        %{"event" => "browser_translation_detected", "props" => %{"app_locale" => "xx"}}
      ])

    assert response(conn, 204)

    assert [
             %{event: "browser_languages_unsupported", props: %{"languages" => ["ar", "he-IL"]}},
             %{
               event: "browser_translation_detected",
               props: %{"to" => "ar", "app_locale" => "en"}
             }
           ] = stored()
  end

  test "drops an unknown event, an undeclared key, and a value of the wrong kind", %{conn: conn} do
    conn =
      send_events(conn, [
        %{"event" => "note_title_typed", "props" => %{}},
        %{
          "event" => "onboarding_step_viewed",
          "props" => %{"step" => "vault", "title" => "done"}
        },
        %{"event" => "onboarding_step_viewed", "props" => %{"step" => "My private journal"}},
        %{"event" => "plugin_connect_started", "props" => %{"vault_id" => "Work/Q3.md"}},
        %{"event" => "checkout_opened", "props" => %{"tier" => %{"nested" => "x"}}},
        %{"event" => "onboarding_step_completed", "props" => %{"duration_ms" => "1200"}},
        %{"event" => "upgrade_link_clicked", "props" => %{"source" => "checklist"}}
      ])

    assert response(conn, 204)
    assert [%Event{event: "upgrade_link_clicked"}] = stored()
  end

  test "refuses a malformed body or more than 20 events", %{conn: conn} do
    many = for _ <- 1..21, do: %{"event" => "plugin_listing_opened"}

    assert json_response(send_events(conn, many), 422)
    assert json_response(post(conn, "/api/analytics/events", %{"events" => "x"}), 422)
    assert json_response(post(conn, "/api/analytics/events", %{}), 422)
    assert stored() == []
  end

  test "stores nothing for a user who opted out", %{conn: conn, user: user} do
    {:ok, _} = Engram.Accounts.set_analytics_opt_out(user)

    conn = send_events(conn, [%{"event" => "plugin_listing_opened"}])
    assert response(conn, 204)
    assert stored() == []
  end

  test "rate limited per user", %{conn: conn} do
    batch = for _ <- 1..20, do: %{"event" => "plugin_listing_opened"}
    statuses = for _ <- 1..8, do: send_events(conn, batch).status

    assert 204 in statuses
    assert List.last(statuses) == 429
  end

  test "browser session only: an API key is refused", %{user: user} do
    {:ok, key, _} = Engram.Accounts.create_api_key(user, "k")
    lift_api_rps_cap!(user)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{key}")
      |> send_events([%{"event" => "plugin_listing_opened"}])

    assert conn.status == 403
    assert stored() == []
  end

  # The server's copy of the web app's schema (frontend/src/analytics/events.ts)
  # must name the same events, or new SPA events are silently dropped here.
  test "accepts exactly the events the web app declares" do
    source = File.read!(Path.expand("../../../frontend/src/analytics/events.ts", __DIR__))
    [union] = Regex.run(~r/export type EngramEvent =(.*?);/s, source, capture: :all_but_first)
    spa = Regex.scan(~r/"([a-z_]+)"/, union, capture: :all_but_first) |> List.flatten()

    assert Enum.sort(spa) == Enum.sort(Engram.Analytics.ClientEvents.names())
  end
end
