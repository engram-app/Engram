defmodule Engram.Analytics.EventLogTest do
  # async: false: flips the app-wide :analytics_event_log flag, and the
  # buffer is one table for the whole node.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Analytics
  alias Engram.Analytics.Event
  alias Engram.Analytics.EventLog
  alias Engram.Workers.AnalyticsEventsPrune

  setup do
    prior = Application.get_env(:engram, :analytics_event_log)
    Application.put_env(:engram, :analytics_event_log, true)
    on_exit(fn -> Application.put_env(:engram, :analytics_event_log, prior) end)
    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  # Rows wait in the buffer until a flush; tests flush by hand.
  defp events do
    :ok = EventLog.flush()
    Repo.all(from(e in Event, order_by: e.inserted_at))
  end

  describe "track/3" do
    test "stores the event with its props, without PostHog configured" do
      refute Analytics.enabled?()
      user = insert(:user)

      Analytics.track(user, "note_created", %{vault_id: "v1", surface: "web"})

      assert [%Event{user_id: id, event: "note_created", props: props}] = events()
      assert id == user.id
      assert props == %{"vault_id" => "v1", "surface" => "web"}
    end

    test "stores nothing for a user who opted out after the struct was loaded" do
      stale = insert(:user)
      {:ok, _} = Engram.Accounts.set_analytics_opt_out(stale)

      Analytics.track(stale, "note_created")
      assert events() == []
    end

    test "stores nothing when the event log is off" do
      Application.put_env(:engram, :analytics_event_log, false)
      Analytics.track(insert(:user), "note_created")
      assert events() == []
    end

    test "is written after the caller's transaction commits, not inside it" do
      user = insert(:user)

      {:error, :rolled_back} =
        Repo.transaction_after_commit(fn ->
          Analytics.track(user, "note_created")
          Repo.rollback(:rolled_back)
        end)

      assert events() == []

      {:ok, _} = Repo.transaction_after_commit(fn -> Analytics.track(user, "vault_created") end)
      assert [%Event{event: "vault_created"}] = events()
    end
  end

  # Free text a user typed (feedback, survey details) and PostHog person
  # updates never reach our table: only the bounded props do.
  test "drops free-text and $-prefixed props" do
    Analytics.track(insert(:user), "user_feedback", %{
      "category" => "bug",
      "message" => "my note about X",
      "detail" => "d",
      "use_cases_detail" => "u",
      "heard_from_detail" => "h",
      "delete_detail" => "x",
      "user_agent" => "ua",
      "$set" => %{"heard_from" => "reddit"}
    })

    assert [%Event{props: %{"category" => "bug"} = props}] = events()
    assert map_size(props) == 1
  end

  # Only keys known to hold a bounded value are stored: a prop added later
  # (free text, an email) is dropped until someone allowlists it.
  test "a reply address given with contact_ok never reaches the table" do
    user = insert(:user, email: "reply-me@example.com")

    :ok =
      Engram.Feedback.submit(user, "general", %{
        "message" => "please call me",
        "contact_ok" => true,
        "category" => "bug"
      })

    assert [%Event{event: "user_feedback", props: props}] = events()
    assert props["contact_ok"] == true
    assert props["category"] == "bug"
    refute Map.has_key?(props, "contact_email")
    refute inspect(props) =~ "reply-me"
  end

  test "drops keys not on the allowlist and clamps long strings" do
    Analytics.track(insert(:user), "note_created", %{
      surface: String.duplicate("w", 500),
      some_future_prop: "free text",
      nested: %{"a" => 1},
      use_cases: ["work", String.duplicate("x", 500)]
    })

    assert [%Event{props: props}] = events()
    assert Map.keys(props) |> Enum.sort() == ["surface", "use_cases"]
    assert String.length(props["surface"]) == 64
    assert ["work", long] = props["use_cases"]
    assert String.length(long) == 64
  end

  # One statement per flush, not one task and insert per event.
  test "buffered events are written in one insert per flush" do
    user = insert(:user)
    for name <- ~w(a b c), do: Analytics.track(user, name)

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:engram, :repo, :query],
      # Handlers run in the querying process: this test's flush only.
      fn _event, _m, meta, _ ->
        if self() == parent and meta.query =~ "INSERT INTO analytics_events",
          do: send(parent, {:insert, ref})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    assert Repo.aggregate(Event, :count) == 0
    assert length(events()) == 3
    assert_received {:insert, ^ref}
    refute_received {:insert, ^ref}
  end

  test "a buffered event of a user deleted before the flush is skipped, not fatal" do
    gone = insert(:user)
    kept = insert(:user)
    Analytics.track(gone, "note_created")
    Analytics.track(kept, "note_created")
    Repo.delete!(gone, skip_tenant_check: true)

    assert [%Event{user_id: id}] = events()
    assert id == kept.id
  end

  test "opting out drops the user's events still waiting in the buffer" do
    user = insert(:user)
    Analytics.track(user, "note_created")
    {:ok, _} = Engram.Accounts.set_analytics_opt_out(user)
    assert events() == []
  end

  test "keeps the time the event happened, not the flush time" do
    user = insert(:user)
    before = DateTime.utc_now()
    Analytics.track(user, "note_created")
    Process.sleep(5)
    flushed_at = DateTime.utc_now()

    assert [%Event{inserted_at: at}] = events()
    assert DateTime.compare(at, before) != :lt
    assert DateTime.compare(at, flushed_at) == :lt
  end

  test "throttled events are stored once per window, like PostHog" do
    user = insert(:user)
    Analytics.track_activity(user, :web)
    Analytics.track_activity(user, :web)

    assert [%Event{event: "surface_active", props: %{"surface" => "web", "events" => 1}}] =
             events()
  end

  # A deleted account's summary must not be joinable back to the deletion:
  # day precision, and a plan coarse enough not to single anyone out.
  test "account_deleted is stored at day precision with a free/paid plan" do
    for plan <- ["pro", "free"], do: Analytics.track_anonymous("account_deleted", %{plan: plan})

    rows = events()
    assert Enum.map(rows, & &1.props["plan"]) |> Enum.sort() == ["free", "paid"]

    for %Event{inserted_at: at} <- rows do
      assert DateTime.to_time(at) == ~T[00:00:00.000000]
      assert DateTime.to_date(at) == Date.utc_today()
    end
  end

  test "an anonymous event is stored with no user" do
    Analytics.track_anonymous("account_deleted", %{plan: "free"})
    assert [%Event{user_id: nil, props: %{"plan" => "free"}}] = events()
  end

  describe "AnalyticsEventsPrune" do
    test "deletes events older than two years and keeps the rest" do
      now = DateTime.utc_now()

      Repo.insert_all(Event, [
        %{event: "old", props: %{}, inserted_at: DateTime.add(now, -731, :day)},
        %{event: "kept", props: %{}, inserted_at: DateTime.add(now, -729, :day)},
        %{event: "new", props: %{}, inserted_at: now}
      ])

      assert {:ok, 1} = perform_job(AnalyticsEventsPrune, %{})
      assert Repo.all(from(e in Event, select: e.event, order_by: e.event)) == ["kept", "new"]
    end
  end
end
