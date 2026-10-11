defmodule Engram.FeedbackTest do
  use Engram.DataCase, async: false

  alias Engram.Accounts.User
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
                 "use_cases" => ["ai_memory", "obsidian_sync"],
                 "detail" => "r/ObsidianMD thread"
               })

      assert %{
               "tools" => ["claude"],
               "heard_from" => "reddit",
               "use_cases" => ["ai_memory", "obsidian_sync"],
               "survey_detail" => "r/ObsidianMD thread"
             } = profile(user)

      assert_receive {:posthog,
                      %{"event" => "onboarding_survey_answered", "properties" => props}},
                     1_000

      assert props["$set"] == %{
               "heard_from" => "reddit",
               "use_cases" => ["ai_memory", "obsidian_sync"]
             }

      assert props["detail"] == "r/ObsidianMD thread"
    end

    test "accepts heard_from alone", %{user: user} do
      assert :ok = Feedback.submit(user, "onboarding", %{"heard_from" => "friend"})
      assert profile(user)["heard_from"] == "friend"
      refute Map.has_key?(profile(user), "use_cases")
    end

    test "rejects an empty submission", %{user: user} do
      assert {:error, :nothing_to_set} = Feedback.submit(user, "onboarding", %{})
      assert {:error, :nothing_to_set} = Feedback.submit(user, "onboarding", %{"use_cases" => []})
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
