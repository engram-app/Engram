defmodule Engram.InsightsTest do
  use Engram.DataCase, async: true

  alias Engram.Analytics.Event
  alias Engram.Insights
  alias Engram.Insights.UserDailyMetric
  alias Engram.Insights.VaultDailyMetric

  defp ago(days, hours \\ 0) do
    DateTime.utc_now()
    |> DateTime.add(-days, :day)
    |> DateTime.add(-hours, :hour)
  end

  defp signup(days_ago, attrs \\ []) do
    insert(:user, Keyword.put(attrs, :created_at, ago(days_ago) |> DateTime.truncate(:second)))
  end

  defp event(user, name, props \\ %{}, at) do
    Repo.insert!(%Event{user_id: user && user.id, event: name, props: props, inserted_at: at})
  end

  defp step(report, name), do: Enum.find(report.steps, &(&1.step == name))

  # A payer: signed up 20 days ago, linked Obsidian, connected an AI app,
  # searched, hit a limit, then paid 10 days ago.
  defp payer do
    u = signup(20)
    insert(:vault, user: u)
    event(u, "plugin_linked", ago(19))
    event(u, "mcp_client_connected", %{"client" => "claude"}, ago(18))

    event(
      u,
      "mcp_tool_called",
      %{"tool" => "search_notes", "client" => "claude", "calls" => 3, "errors" => 1},
      ago(18)
    )

    event(u, "search_performed", %{"status" => "ok"}, ago(17))
    event(u, "surface_active", %{"surface" => "mcp"}, ago(17))
    event(u, "limit_hit", %{"limit_key" => "notes_cap"}, ago(12))
    event(u, "payment_completed", %{"amount_bucket" => "under_10"}, ago(10))
    u
  end

  describe "funnel" do
    test "counts each step, its share of signups and time from the step before" do
      payer()
      browser = signup(5)
      event(browser, "surface_active", %{"surface" => "web"}, ago(4))
      _idle = signup(3)

      f = Insights.report("funnel", :all)

      assert step(f, "signed_up").users == 3
      assert step(f, "obsidian_linked").users == 1
      assert step(f, "obsidian_linked").pct == 33.3
      assert step(f, "first_search").users == 1
      assert step(f, "paid").users == 1
      assert step(f, "day2_return").users == 2
      assert step(f, "day7_return").users == 0
      assert step(f, "vault_created").users == 1
      assert is_float(step(f, "obsidian_linked").median_hours_from_previous)
      assert Enum.sum(Enum.map(f.by_week, & &1.counts["signed_up"])) == 3
      assert [%{source: "direct", counts: %{"signed_up" => 3}}] = f.by_source
    end

    test "a 100%-off comp is not a payment" do
      u = signup(5)
      event(u, "payment_completed", %{"amount_bucket" => "0", "discounted" => true}, ago(1))
      event(u, "subscription_started", %{"discounted" => true}, ago(1))
      assert step(Insights.report("funnel", :all), "paid").users == 0
    end

    test "leaves out operators and users who opted out" do
      signup(2, role: "operator")
      signup(2, analytics_opt_out_at: DateTime.utc_now())
      assert step(Insights.report("funnel", :all), "signed_up").users == 0
    end
  end

  test "converters: the payer's state the day before paying vs peers at the same tenure" do
    p = payer()
    peer = signup(15)
    paid_day = Date.add(Date.utc_today(), -10)

    Repo.insert!(%UserDailyMetric{
      user_id: p.id,
      date: Date.add(paid_day, -1),
      captured_at: DateTime.utc_now(),
      notes: 40,
      obsidian_devices: 1
    })

    Repo.insert!(%UserDailyMetric{
      user_id: peer.id,
      date: Date.add(Date.utc_today(), -6),
      captured_at: DateTime.utc_now(),
      notes: 4
    })

    assert %{converters: [row]} = Insights.report("converters", :all)
    assert row.user_id == p.id
    assert row.tenure_days == 10
    assert row.before_paying.notes == 40
    assert row.before_paying.limits_hit == 1
    assert row.before_paying.tools_used == 1
    assert row.before_paying.days_active == 1
    assert row.peers == 1
    assert row.peers_median.notes == 4
  end

  test "path_to_paid lists first-time steps in order, ending at paid" do
    p = payer()
    signup(3)

    assert %{paths: [%{user_id: id, steps: steps}]} = Insights.report("path_to_paid", :all)
    assert id == p.id

    assert Enum.map(steps, & &1.step) ==
             ~w(signed_up obsidian_linked ai_connected first_search day2_return paid)
  end

  test "limits: who hit each limit and what they did next" do
    payer()
    quitter = signup(40)
    event(quitter, "limit_hit", %{"limit_key" => "notes_cap"}, ago(30))
    stayer = signup(10)
    event(stayer, "limit_hit", %{"limit_key" => "ai_searches_per_day"}, ago(5))
    event(stayer, "surface_active", %{"surface" => "web"}, ago(1))

    %{limits: limits} = Insights.report("limits", :all)
    notes = Enum.find(limits, &(&1["limit_key"] == "notes_cap"))
    assert notes["users"] == 2
    assert notes["upgraded"] == 1
    assert notes["churned"] == 1
    assert Enum.find(limits, &(&1["limit_key"] == "ai_searches_per_day"))["stayed"] == 1
  end

  test "surfaces: users per surface per day and per surface mix" do
    a = signup(5)
    b = signup(5)
    event(a, "surface_active", %{"surface" => "web"}, ago(1))
    event(a, "surface_active", %{"surface" => "mcp"}, ago(1))
    event(b, "surface_active", %{"surface" => "web"}, ago(1))
    event(b, "note_created", %{"surface" => "welcome"}, ago(1))

    s = Insights.report("surfaces", :all)
    assert [%{"web" => 2, "mcp" => 1}] = s.by_day
    assert Enum.sort_by(s.mix, & &1.mix) == [%{mix: "mcp+web", users: 1}, %{mix: "web", users: 1}]
  end

  test "ai_apps: clients, clients per user, tool volume and error rates" do
    p = payer()
    event(p, "mcp_client_connected", %{"client" => "cursor"}, ago(2))

    a = Insights.report("ai_apps", :all)

    assert Enum.sort_by(a.clients, & &1.client) == [
             %{client: "claude", users: 1},
             %{client: "cursor", users: 1}
           ]

    assert a.clients_per_user == [%{clients: 2, users: 1}]
    assert [%{tool: "search_notes", calls: 3, errors: 1, error_pct: 33.3}] = a.tools
    assert [%{client: "claude", calls: 3}] = a.by_client
  end

  test "vaults: size distributions from the latest snapshot, vaults per user, growth" do
    u = signup(5)
    v1 = insert(:vault, user: u)
    v2 = insert(:vault, user: u)
    today = Date.add(Date.utc_today(), -1)

    for {v, notes, date} <- [{v1, 10, today}, {v2, 30, today}, {v1, 5, Date.add(today, -1)}] do
      Repo.insert!(%VaultDailyMetric{vault_id: v.id, user_id: u.id, date: date, notes: notes})
    end

    r = Insights.report("vaults", :all)
    assert r.date == today
    assert r.vaults == 2
    assert r.notes.median == 20.0
    assert r.notes.total == 40
    assert r.vaults_per_user == [%{vaults: 2, users: 1}]
    assert [%{notes: 5}, %{notes: 40, vaults: 2}] = r.growth
  end

  test "retention: weekly cohorts, split by first surface and AI connection" do
    payer()
    _quiet = signup(20)

    %{cohorts: cohorts} = Insights.report("retention", :all)
    all = Enum.filter(cohorts, &(&1.split == "all"))
    assert Enum.sum(Enum.map(all, & &1.size)) == 2
    # The payer was active once, 3 days after signing up.
    assert Enum.any?(all, fn c -> Enum.any?(c.weeks, &(&1 == 50.0)) end)

    assert Enum.any?(cohorts, &(&1.split == "first_surface" and &1.value == "mcp"))
    assert Enum.find(cohorts, &(&1.split == "ai_connected" and &1.value == "yes")).size == 1
  end

  test "billing: lifecycle counts and MRR without comped accounts" do
    p = payer()
    insert(:subscription, user: p, tier: "pro", status: "active")
    comped = signup(5)
    insert(:subscription, user: comped, tier: "pro", status: "active")
    event(comped, "payment_completed", %{"amount_bucket" => "0"}, ago(1))
    event(p, "subscription_changed", %{"kind" => "upgrade"}, ago(2))
    event(p, "subscription_cancel_reason", %{"reason" => "too_expensive"}, ago(1))
    event(p, "subscription_trial_started", ago(19))

    b = Insights.report("billing", :all)
    assert b.trials == 1
    assert b.upgrades == 1
    assert b.cancel_reasons == %{"too_expensive" => 1}
    assert b.paying_subscriptions == %{"pro" => 1}
    assert b.unverified_subscriptions == 1
    assert b.mrr_usd == 14
  end

  test "churn_signals: dropped activity and disconnected devices or AI apps" do
    dropping = signup(40)

    for d <- [20, 21, 22, 23],
        do: event(dropping, "surface_active", %{"surface" => "web"}, ago(d))

    disconnected = signup(40)
    event(disconnected, "device_disconnected", %{"via" => "device_flow"}, ago(2))
    event(disconnected, "mcp_client_disconnected", %{"via" => "oauth"}, ago(2))
    steady = signup(40)
    for d <- [1, 2, 20, 21], do: event(steady, "surface_active", %{"surface" => "web"}, ago(d))

    %{users: users} = Insights.report("churn_signals", :all)
    by_user = Map.new(users, &{&1.user_id, &1.signals})
    assert by_user[dropping.id] == ["activity_dropped"]
    assert by_user[disconnected.id] == ["device_disconnected", "ai_app_disconnected"]
    refute Map.has_key?(by_user, steady.id)
  end

  describe "timeline/2" do
    test "every event and snapshot of one account, oldest first" do
      u = signup(5)
      other = signup(5)
      event(u, "vault_created", ago(4))
      event(u, "note_created", %{"surface" => "web"}, ago(3))
      event(other, "vault_created", ago(4))
      Repo.insert!(%UserDailyMetric{user_id: u.id, date: Date.utc_today(), notes: 1})

      t = Insights.timeline(u.id, :all)
      assert Enum.map(t.events, & &1.event) == ["vault_created", "note_created"]
      assert [%{notes: 1}] = t.days
    end

    test "nil for an operator or unknown account" do
      assert Insights.timeline(signup(1, role: "operator").id, :all) == nil
      assert Insights.timeline(Ecto.UUID.generate(), :all) == nil
    end
  end

  # #11: a user who paid LATER still was a non-payer at the payer's tenure,
  # so they are a peer; one who had already paid by then is not.
  test "converters: a user who paid after the cutoff is still a peer" do
    p = payer()
    later = signup(18)
    event(later, "payment_completed", %{"amount_bucket" => "under_10"}, ago(1))
    earlier = signup(19)
    event(earlier, "payment_completed", %{"amount_bucket" => "under_10"}, ago(15))

    %{converters: rows} = Insights.report("converters", :all)
    row = Enum.find(rows, &(&1.user_id == p.id))
    # later: cutoff 8 days ago, paid 1 day ago -> peer. earlier: paid 15 days
    # ago, before its cutoff 9 days ago -> not a peer.
    assert row.peers == 1
  end

  describe "date window" do
    test "a report covers the last :days (default 180), capped at 730" do
      old = signup(200)
      event(old, "surface_active", %{"surface" => "web"}, ago(199))
      signup(10)

      assert step(Insights.report("funnel", :all), "signed_up").users == 1
      assert step(Insights.report("funnel", :all, days: 365), "signed_up").users == 2
      assert step(Insights.report("funnel", :all, days: 5), "signed_up").users == 0
      assert step(Insights.report("funnel", :all, days: 100_000), "signed_up").users == 2
      assert Insights.window_days(nil) == 180
      assert Insights.window_days(0) == 1
      assert Insights.window_days(10_000) == 730
    end
  end

  # Aggregation runs in SQL: a report reads a fixed number of queries, each
  # returning rows per user (or per user-week), never one row per event.
  test "reports do not load per-event rows" do
    users = for d <- 1..5, do: signup(20 + d)
    now = DateTime.utc_now()

    rows =
      for u <- users, i <- 1..600 do
        name = Enum.at(~w(surface_active mcp_tool_called limit_hit search_performed), rem(i, 4))

        %{
          user_id: u.id,
          event: name,
          props: %{
            "surface" => "web",
            "tool" => "t#{rem(i, 3)}",
            "client" => "claude",
            "limit_key" => "notes_cap",
            "calls" => 1
          },
          inserted_at: DateTime.add(now, -rem(i, 19 * 24), :hour)
        }
      end

    {3000, _} = Repo.insert_all(Event, rows)
    event(hd(users), "payment_completed", %{"amount_bucket" => "under_10"}, ago(2))

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:engram, :repo, :query],
      # Handlers run in the querying process: count only this test's queries,
      # not those of async tests running alongside.
      # Other tests emit this event with no `:result` (QueryRecorderTest): a
      # raising handler is detached by telemetry and every later count is empty.
      fn _event, _measure, meta, _ ->
        with true <- self() == parent,
             {:ok, %{num_rows: n}} <- Map.get(meta, :result) do
          send(parent, {:rows, ref, n})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    # Reproduce that neighbour deterministically instead of by async timing.
    Task.await(
      Task.async(fn ->
        Engram.QueryRecorder.emit_foreign_query()
      end)
    )

    for name <- Insights.reports() do
      _ = Insights.report(name, :all)
      counts = drain_rows(ref)
      assert counts != [], "#{name} recorded no queries: the handler is gone"
      assert length(counts) <= 12, "#{name} ran #{length(counts)} queries"
      assert Enum.max(counts) <= 200, "#{name} loaded #{Enum.max(counts)} rows"
    end
  end

  defp drain_rows(ref, acc \\ []) do
    receive do
      {:rows, ^ref, n} -> drain_rows(ref, [n | acc])
    after
      0 -> acc
    end
  end

  test "only :all is a scope" do
    assert_raise FunctionClauseError, fn -> Insights.report("funnel", {:org, "x"}) end
    assert_raise FunctionClauseError, fn -> Insights.report("nope", :all) end
  end
end
