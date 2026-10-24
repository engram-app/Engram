defmodule Engram.FeedbackTest do
  use Engram.DataCase, async: false

  alias Engram.Accounts.User
  alias Engram.Analytics.Event
  alias Engram.Analytics.EventLog
  alias Engram.Feedback

  setup do
    prior_key = Application.get_env(:engram, :posthog_key)
    prior_host = Application.get_env(:engram, :posthog_host)

    on_exit(fn ->
      Application.put_env(:engram, :posthog_key, prior_key)
      Application.put_env(:engram, :posthog_host, prior_host)
    end)

    bypass = Bypass.open()
    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")

    parent = self()

    Bypass.stub(bypass, "POST", "/capture/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:posthog, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "1")
    end)

    {:ok, user: insert(:user, onboarding_profile: %{"tools" => ["claude"]})}
  end

  defp profile(user), do: Repo.get!(User, user.id, skip_tenant_check: true).onboarding_profile

  describe "onboarding" do
    test "stores answers in onboarding_profile without clobbering it, and sets person props",
         %{user: user} do
      assert :ok =
               Feedback.submit(user, "onboarding", %{
                 "heard_from" => "reddit",
                 "use_cases" => ["ai_memory", "other"],
                 "use_cases_detail" => "  a shared team wiki  ",
                 "heard_from_detail" => "r/ObsidianMD thread"
               })

      assert %{
               "tools" => ["claude"],
               "heard_from" => "reddit",
               "use_cases" => ["ai_memory", "other"],
               "use_cases_detail" => "a shared team wiki",
               "heard_from_detail" => "r/ObsidianMD thread"
             } = profile(user)

      assert_receive {:posthog,
                      %{"event" => "onboarding_survey_answered", "properties" => props}},
                     1_000

      assert props["$set"] == %{
               "heard_from" => "reddit",
               "use_cases" => ["ai_memory", "other"]
             }

      # On the event too, not only in $set: PostHog drops $set from the stored
      # event, so event breakdowns would read null without these.
      assert props["heard_from"] == "reddit"
      assert props["use_cases"] == ["ai_memory", "other"]
      assert props["use_cases_detail"] == "a shared team wiki"
      assert props["heard_from_detail"] == "r/ObsidianMD thread"
    end

    test "accepts heard_from alone", %{user: user} do
      assert :ok = Feedback.submit(user, "onboarding", %{"heard_from" => "obsidian_plugins"})
      assert profile(user)["heard_from"] == "obsidian_plugins"
      refute Map.has_key?(profile(user), "use_cases")
    end

    test "stamps survey_done_at when answered", %{user: user} do
      assert :ok = Feedback.submit(user, "onboarding", %{"heard_from" => "friend"})
      assert is_binary(profile(user)["survey_done_at"])
    end

    test "an empty submission is a skip: stamps survey_done_at, sends nothing", %{user: user} do
      assert :ok = Feedback.submit(user, "onboarding", %{"use_cases" => []})
      assert %{"tools" => ["claude"], "survey_done_at" => ts} = profile(user)
      assert is_binary(ts)
      refute_receive {:posthog, _}, 200
    end

    # The in-app survey always sends `use_cases` (empty on skip); the terms
    # screen's heard-from answer never does. Only the survey stamps this, so
    # the app can tell whether it was asked.
    test "a submission carrying use_cases stamps use_cases_done_at", %{user: user} do
      assert :ok = Feedback.submit(user, "onboarding", %{"use_cases" => []})
      assert is_binary(profile(user)["use_cases_done_at"])
    end

    test "a heard-from answer alone does not stamp use_cases_done_at", %{user: user} do
      assert :ok = Feedback.submit(user, "onboarding", %{"heard_from" => "friend"})
      refute Map.has_key?(profile(user), "use_cases_done_at")
    end

    # The in-app survey saves tools and use cases in ONE request: two requests
    # let the first flip the survey to answered (and unmount it) before the
    # second could report a failure.
    test "saves tools onto the profile alongside use cases", %{user: user} do
      assert :ok =
               Feedback.submit(user, "onboarding", %{
                 "use_cases" => ["search"],
                 "tools" => ["chatgpt", "cursor"]
               })

      assert %{"tools" => ["chatgpt", "cursor"], "use_cases" => ["search"]} = profile(user)
    end

    test "rejects unknown or empty tools", %{user: user} do
      assert {:error, :invalid_tools} =
               Feedback.submit(user, "onboarding", %{"tools" => ["telepathy"]})

      assert {:error, :invalid_tools} = Feedback.submit(user, "onboarding", %{"tools" => []})

      # Atomic: a rejected survey save stamps nothing, so it is asked again.
      refute Map.has_key?(profile(user), "use_cases_done_at")
      assert profile(user)["tools"] == ["claude"]
    end

    test "rejects unknown slugs", %{user: user} do
      assert {:error, :invalid_heard_from} =
               Feedback.submit(user, "onboarding", %{"heard_from" => "tv"})

      assert {:error, :invalid_use_cases} =
               Feedback.submit(user, "onboarding", %{"use_cases" => ["ai_memory", "telepathy"]})

      assert {:error, :invalid_use_cases} =
               Feedback.submit(user, "onboarding", %{"use_cases" => "ai_memory"})

      assert profile(user) == %{"tools" => ["claude"]}
    end
  end

  describe "cancel" do
    test "captures the reason and sets the person prop", %{user: user} do
      assert :ok =
               Feedback.submit(user, "cancel", %{
                 "reason" => "too_expensive",
                 "detail" => "$7 hurts"
               })

      assert_receive {:posthog,
                      %{"event" => "subscription_cancel_reason", "properties" => props}},
                     1_000

      assert props["reason"] == "too_expensive"
      assert props["detail"] == "$7 hurts"
      assert props["$set"] == %{"cancel_reason" => "too_expensive"}
    end

    test "requires a known reason", %{user: user} do
      assert {:error, :invalid_reason} = Feedback.submit(user, "cancel", %{})
      assert {:error, :invalid_reason} = Feedback.submit(user, "cancel", %{"reason" => "meh"})
    end
  end

  describe "record_missing_cancel_reason/3" do
    setup do
      prior = Application.get_env(:engram, :analytics_event_log)
      Application.put_env(:engram, :analytics_event_log, true)
      on_exit(fn -> Application.put_env(:engram, :analytics_event_log, prior) end)
      :ok
    end

    defp reasons(user) do
      :ok = EventLog.flush()

      Repo.all(
        from(e in Event,
          where: e.user_id == ^user.id and e.event == "subscription_cancel_reason",
          select: e.props["reason"]
        )
      )
    end

    test "files the marker when no reason was given since the subscription started",
         %{user: user} do
      since = DateTime.add(DateTime.utc_now(), -3600)
      assert :ok = Feedback.record_missing_cancel_reason(user, since, "portal_no_reason")
      assert reasons(user) == ["portal_no_reason"]
    end

    test "files nothing when the in-app dialog already captured a reason", %{user: user} do
      since = DateTime.add(DateTime.utc_now(), -3600)
      :ok = Feedback.submit(user, "cancel", %{"reason" => "too_expensive"})
      :ok = EventLog.flush()

      assert :ok = Feedback.record_missing_cancel_reason(user, since, "portal_no_reason")
      assert reasons(user) == ["too_expensive"]
    end

    defp log_event(user, event, props, seconds_ago) do
      Repo.insert!(%Event{
        user_id: user.id,
        event: event,
        props: props,
        inserted_at: DateTime.add(DateTime.utc_now(), -seconds_ago)
      })
    end

    test "a reason given for an earlier, reversed cancel does not cover a later one",
         %{user: user} do
      started = DateTime.add(DateTime.utc_now(), -30 * 86_400)
      log_event(user, "subscription_changed", %{"kind" => "cancel_scheduled"}, 20 * 86_400)
      log_event(user, "subscription_cancel_reason", %{"reason" => "too_expensive"}, 20 * 86_400)
      # Reversed, then cancelled again in the portal: no reason this time.
      log_event(user, "subscription_changed", %{"kind" => "cancel_reversed"}, 10 * 86_400)
      log_event(user, "subscription_changed", %{"kind" => "cancel_scheduled"}, 2 * 86_400)

      assert :ok = Feedback.record_missing_cancel_reason(user, started, "portal_no_reason")
      assert Enum.sort(reasons(user)) == ["portal_no_reason", "too_expensive"]
    end

    test "a dialog reason filed just after the scheduled-cancel event still counts",
         %{user: user} do
      started = DateTime.add(DateTime.utc_now(), -30 * 86_400)
      log_event(user, "subscription_cancel_reason", %{"reason" => "not_using"}, 2 * 86_400 + 5)
      log_event(user, "subscription_changed", %{"kind" => "cancel_scheduled"}, 2 * 86_400)

      assert :ok = Feedback.record_missing_cancel_reason(user, started, "portal_no_reason")
      assert reasons(user) == ["not_using"]
    end

    # Paddle re-sends cancel_scheduled on every update while a cancel is
    # pending; a later one must not push the dialog's reason out of the window.
    test "a later cancel_scheduled resend does not hide the dialog's reason", %{user: user} do
      started = DateTime.add(DateTime.utc_now(), -30 * 86_400)
      log_event(user, "subscription_changed", %{"kind" => "cancel_scheduled"}, 10 * 86_400)
      log_event(user, "subscription_cancel_reason", %{"reason" => "not_using"}, 10 * 86_400 - 5)
      log_event(user, "subscription_changed", %{"kind" => "cancel_scheduled"}, 3 * 86_400)

      assert :ok = Feedback.record_missing_cancel_reason(user, started, "portal_no_reason")
      assert reasons(user) == ["not_using"]
    end

    test "an in-app reverse ends the cancel episode", %{user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_reverse_episode")

      Mox.expect(Engram.Paddle.ClientMock, :update_subscription, fn _, _, _ ->
        {:ok, %{"scheduled_change" => nil}}
      end)

      assert {:ok, _} = Engram.Billing.Subscriptions.reverse_cancel(user)
      :ok = EventLog.flush()

      assert [%{"kind" => "cancel_reversed"}] =
               Repo.all(
                 from(e in Event,
                   where: e.user_id == ^user.id and e.event == "subscription_changed",
                   select: e.props
                 )
               )
    end

    test "payment_failed is filed even when a reason is on file", %{user: user} do
      started = DateTime.add(DateTime.utc_now(), -30 * 86_400)
      log_event(user, "subscription_cancel_reason", %{"reason" => "too_expensive"}, 86_400)

      assert :ok = Feedback.record_missing_cancel_reason(user, started, "payment_failed")
      assert Enum.sort(reasons(user)) == ["payment_failed", "too_expensive"]
    end

    test "files nothing when the event log is off, since every cancel would look reasonless",
         %{user: user} do
      Application.put_env(:engram, :analytics_event_log, false)
      since = DateTime.add(DateTime.utc_now(), -3600)

      assert :ok = Feedback.record_missing_cancel_reason(user, since, "portal_no_reason")
      refute_receive {:posthog, %{"event" => "subscription_cancel_reason"}}, 300
    end

    test "a reason from before this subscription started does not count", %{user: user} do
      :ok = Feedback.submit(user, "cancel", %{"reason" => "too_expensive"})
      :ok = EventLog.flush()
      since = DateTime.add(DateTime.utc_now(), 3600)

      assert :ok = Feedback.record_missing_cancel_reason(user, since, "portal_no_reason")
      assert Enum.sort(reasons(user)) == ["portal_no_reason", "too_expensive"]
    end
  end

  describe "delete_account" do
    test "stashes the answer on the user row and sends nothing yet", %{user: user} do
      assert :ok =
               Feedback.submit(user, "delete_account", %{
                 "reason" => "switched_tool",
                 "detail" => " went back to Obsidian, mail me at jane.doe@example.com "
               })

      assert %{
               "tools" => ["claude"],
               "delete_reason" => "switched_tool",
               "delete_detail" => "went back to Obsidian, mail me at [email]"
             } = profile(user)

      refute_receive {:posthog, _}, 200
    end

    test "a second submit replaces the first", %{user: user} do
      assert :ok = Feedback.submit(user, "delete_account", %{"reason" => "too_expensive"})
      assert :ok = Feedback.submit(user, "delete_account", %{"detail" => "just leaving"})

      assert %{"delete_reason" => nil, "delete_detail" => "just leaving"} = profile(user)
    end

    test "rejects an unknown reason and an empty answer", %{user: user} do
      assert {:error, :invalid_reason} =
               Feedback.submit(user, "delete_account", %{"reason" => "meh"})

      assert {:error, :empty_message} =
               Feedback.submit(user, "delete_account", %{"detail" => "   "})
    end
  end

  describe "capture_delete_reason/1" do
    test "sends the stashed answer anonymously" do
      assert :ok =
               Feedback.capture_delete_reason(%{
                 "delete_reason" => "switched_tool",
                 "delete_detail" => "went back to Obsidian"
               })

      assert_receive {:posthog,
                      %{
                        "event" => "account_delete_reason",
                        "distinct_id" => distinct_id,
                        "properties" => props
                      }},
                     1_000

      assert {:ok, _} = Ecto.UUID.cast(distinct_id)
      assert props["reason"] == "switched_tool"
      assert props["detail"] == "went back to Obsidian"
      assert props["$process_person_profile"] == false
    end

    test "sends nothing when no answer was given" do
      assert :ok = Feedback.capture_delete_reason(%{"tools" => ["claude"]})
      assert :ok = Feedback.capture_delete_reason(nil)
      refute_receive {:posthog, _}, 200
    end
  end

  describe "general" do
    test "captures the message", %{user: user} do
      assert :ok = Feedback.submit(user, "general", %{"message" => "  search misses tags  "})

      assert_receive {:posthog, %{"event" => "user_feedback", "properties" => props}}, 1_000
      assert props["message"] == "search misses tags"
    end

    test "rejects a blank message", %{user: user} do
      assert {:error, :empty_message} = Feedback.submit(user, "general", %{"message" => "   "})
      assert {:error, :empty_message} = Feedback.submit(user, "general", %{})
    end

    test "carries category, mood, contact consent and client context", %{user: user} do
      assert :ok =
               Feedback.submit(user, "general", %{
                 "message" => "sync stalls",
                 "category" => "bug",
                 "mood" => 2,
                 "contact_ok" => true,
                 "source" => "plugin",
                 "app_version" => "1.33.4",
                 "area" => "settings/sync",
                 "user_agent" => "Mozilla/5.0 obsidian/1.9.10"
               })

      assert_receive {:posthog, %{"event" => "user_feedback", "properties" => props}}, 1_000

      assert %{
               "category" => "bug",
               "mood" => 2,
               "contact_ok" => true,
               "source" => "plugin",
               "app_version" => "1.33.4",
               "area" => "settings/sync",
               "user_agent" => "Mozilla/5.0 obsidian/1.9.10",
               "plan" => "free"
             } = props

      assert is_binary(props["server_version"])
    end

    test "defaults source to web and contact_ok to false", %{user: user} do
      assert :ok = Feedback.submit(user, "general", %{"message" => "hi"})
      assert_receive {:posthog, %{"properties" => props}}, 1_000
      assert props["source"] == "web"
      assert props["contact_ok"] == false
      refute Map.has_key?(props, "category")
      refute Map.has_key?(props, "mood")
    end

    test "accepts MCP fields and rejects a bad initiated_by or tool_name", %{user: user} do
      assert :ok =
               Feedback.submit(user, "general", %{
                 "message" => "hi",
                 "source" => "mcp",
                 "category" => "missing_capability",
                 "initiated_by" => "model",
                 "tool_name" => "search_notes"
               })

      assert_receive {:posthog, %{"properties" => props}}, 1_000
      assert props["initiated_by"] == "model"
      assert props["tool_name"] == "search_notes"

      base = %{"message" => "hi", "source" => "mcp"}

      assert {:error, :invalid_initiated_by} =
               Feedback.submit(user, "general", Map.put(base, "initiated_by", "bot"))

      # A tool name that is not a plain identifier is dropped, not stored.
      assert :ok =
               Feedback.submit(user, "general", Map.put(base, "tool_name", "Diary.md secret"))

      assert_receive {:posthog, %{"properties" => props}}, 1_000
      refute Map.has_key?(props, "tool_name")
    end

    test "rejects an unknown category, mood or source", %{user: user} do
      base = %{"message" => "hi"}

      assert {:error, :invalid_category} =
               Feedback.submit(user, "general", Map.put(base, "category", "rant"))

      for mood <- [0, 6, "3", 2.5] do
        assert {:error, :invalid_mood} =
                 Feedback.submit(user, "general", Map.put(base, "mood", mood))
      end

      assert {:error, :invalid_source} =
               Feedback.submit(user, "general", Map.put(base, "source", "ios"))
    end

    test "drops overlong client tokens and caps the user agent", %{user: user} do
      assert :ok =
               Feedback.submit(user, "general", %{
                 "message" => "hi",
                 "app_version" => String.duplicate("9", 500),
                 "area" => String.duplicate("a", 500),
                 "user_agent" => String.duplicate("u", 500)
               })

      assert_receive {:posthog, %{"properties" => props}}, 1_000
      # Overlong tokens are dropped, not truncated: a cut value is a wrong one.
      refute Map.has_key?(props, "app_version")
      refute Map.has_key?(props, "area")
      assert String.length(props["user_agent"]) == 300
    end
  end

  describe "general reply consent" do
    test "carries the email only when the user said we can reply", %{user: user} do
      assert :ok = Feedback.submit(user, "general", %{"message" => "hi"})
      assert_receive {:posthog, %{"properties" => props}}, 1_000
      refute Map.has_key?(props, "contact_email")

      assert :ok = Feedback.submit(user, "general", %{"message" => "hi", "contact_ok" => true})
      assert_receive {:posthog, %{"properties" => props}}, 1_000
      assert props["contact_email"] == user.email
    end

    test "drops a client area or version that is not a plain token", %{user: user} do
      assert :ok =
               Feedback.submit(user, "general", %{
                 "message" => "hi",
                 "area" => "x`\nuser forged a@b.com",
                 "app_version" => "1.0 a@b.com"
               })

      assert_receive {:posthog, %{"properties" => props}}, 1_000
      refute Map.has_key?(props, "area")
      refute Map.has_key?(props, "app_version")
    end
  end

  test "caps free text at 2000 chars", %{user: user} do
    long = String.duplicate("a", 2_500)
    assert :ok = Feedback.submit(user, "general", %{"message" => long})
    assert_receive {:posthog, %{"properties" => %{"message" => msg}}}, 1_000
    assert String.length(msg) == 2_000
  end

  test "rejects an unknown kind", %{user: user} do
    assert {:error, :invalid_kind} = Feedback.submit(user, "spam", %{"message" => "hi"})
  end
end
