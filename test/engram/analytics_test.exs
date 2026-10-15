defmodule Engram.AnalyticsTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Analytics
  alias Engram.Observability.PostHog
  alias Engram.Workers.PostHogErasure

  import Ecto.Query, only: [where: 2]

  setup do
    prior_key = Application.get_env(:engram, :posthog_key)
    prior_host = Application.get_env(:engram, :posthog_host)

    on_exit(fn ->
      Application.put_env(:engram, :posthog_key, prior_key)
      Application.put_env(:engram, :posthog_host, prior_host)
    end)

    EngramWeb.RateLimiter.reset_buckets!()
    bypass = Bypass.open()
    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")
    parent = self()

    Bypass.stub(bypass, "POST", "/capture/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:captured, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "1")
    end)

    :ok
  end

  defp enable_erasure do
    for k <- [:posthog_erasure_api_key, :posthog_project_id] do
      prev = Application.get_env(:engram, k)
      on_exit(fn -> Application.put_env(:engram, k, prev) end)
    end

    Application.put_env(:engram, :posthog_erasure_api_key, "phx_test_key")
    Application.put_env(:engram, :posthog_project_id, "1")
  end

  describe "track/3" do
    test "sends the event under the user's analytics id" do
      user = insert(:user, email: "t@example.com")
      assert :ok = Analytics.track(user, "note_created", %{vault_id: "v"})

      assert_receive {:captured, body}, 1_000
      assert body["event"] == "note_created"
      assert body["distinct_id"] == PostHog.analytics_id("t@example.com")
      assert body["properties"]["vault_id"] == "v"
    end

    test "reads the user fresh, so a struct held since before an opt-out sends nothing" do
      # A long-lived socket keeps the User struct it joined with.
      stale = insert(:user, email: "held@example.com")
      {:ok, _} = Engram.Accounts.set_analytics_opt_out(stale)

      assert :ok = Analytics.track(stale, "note_created")
      refute_receive {:captured, _}, 200
    end

    test "uses the current email, not the one on a stale struct" do
      stale = insert(:user, email: "before@example.com")

      stale
      |> Ecto.Changeset.change(email: "after@example.com")
      |> Repo.update!(skip_tenant_check: true)

      assert :ok = Analytics.track(stale, "note_created")
      assert_receive {:captured, body}, 1_000
      assert body["distinct_id"] == PostHog.analytics_id("after@example.com")
    end

    test "sends nothing for a deleted user" do
      user = insert(:user)
      Repo.delete!(user, skip_tenant_check: true)

      assert :ok = Analytics.track(user, "note_created")
      refute_receive {:captured, _}, 200
    end
  end

  describe "track_activity/3" do
    test "emits surface_active once per user and surface per window" do
      user = insert(:user, email: "act@example.com")

      for _ <- 1..3, do: assert(:ok = Analytics.track_activity(user, :mcp))

      assert_receive {:captured, body}, 1_000
      assert body["event"] == "surface_active"
      assert body["properties"]["surface"] == "mcp"
      refute_receive {:captured, _}, 300
    end

    test "skips a user who opted out after the struct was loaded" do
      stale = insert(:user)
      {:ok, _} = Engram.Accounts.set_analytics_opt_out(stale)

      assert :ok = Analytics.track_activity(stale, :obsidian_sync)
      refute_receive {:captured, _}, 200
    end
  end

  describe "track_anonymous/2" do
    test "sends a person-less event" do
      assert :ok = Analytics.track_anonymous("account_delete_reason", %{"reason" => "x"})

      assert_receive {:captured, body}, 1_000
      assert body["properties"]["$process_person_profile"] == false
      assert body["properties"]["reason"] == "x"
    end
  end

  describe "client_id/1 and opted_out?/1" do
    test "nil and true for an opted-out user" do
      user = insert(:user, analytics_opt_out_at: DateTime.utc_now())
      assert Analytics.client_id(user) == nil
      assert Analytics.opted_out?(user)
    end

    test "the analytics id and false otherwise" do
      user = insert(:user, email: "c@example.com")
      assert Analytics.client_id(user) == PostHog.analytics_id("c@example.com")
      refute Analytics.opted_out?(user)
    end
  end

  describe "forget/1" do
    test "queues nothing when erasure is not configured (self-host, dev)" do
      Application.delete_env(:engram, :posthog_erasure_api_key)
      assert :ok = Analytics.forget(insert(:user))
      assert all_enqueued(worker: PostHogErasure) == []
    end

    test "erases every id the user is known by, now and again after any in-flight sync" do
      enable_erasure()
      user = insert(:user, email: "f@example.com", external_id: "user_legacy")
      ids = [PostHog.analytics_id("f@example.com"), "user_legacy"]

      assert :ok = Analytics.forget(user)

      jobs = all_enqueued(worker: PostHogErasure)
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.args == %{"distinct_ids" => ids}))

      assert Enum.any?(jobs, fn job ->
               DateTime.diff(job.scheduled_at, DateTime.utc_now(), :minute) in 9..10
             end)
    end
  end

  describe "cancel_pending_erasure/1" do
    # A user who opts back in must not lose what they send after consenting
    # again. Any erasure still pending (scheduled re-erase, queued, or retrying
    # through a PostHog outage) would delete the whole person when it runs.
    test "cancels every pending erasure of the user, in any waiting state" do
      enable_erasure()
      user = insert(:user, email: "back@example.com", external_id: nil)
      other = insert(:user, email: "other@example.com", external_id: nil)
      :ok = Analytics.forget(user)
      :ok = Analytics.forget(other)
      mine = %{"distinct_ids" => [PostHog.analytics_id("back@example.com")]}

      {:ok, retrying} = PostHogErasure.enqueue(mine["distinct_ids"])
      Repo.update_all(where(Oban.Job, id: ^retrying.id), set: [state: "retryable"])

      assert :ok = Analytics.cancel_pending_erasure(user)

      states =
        Oban.Job
        |> where(worker: ^inspect(PostHogErasure))
        |> Repo.all()
        |> Enum.group_by(&(&1.args == mine), & &1.state)

      assert Enum.sort(states[true]) == ["cancelled", "cancelled", "cancelled"]
      assert Enum.sort(states[false]) == ["available", "scheduled"]
    end
  end

  describe "set_analytics_opt_out/1" do
    # Erasure is the legal half of an opt-out: a repeat (user re-toggling, or an
    # operator re-running a privacy@ request) must queue it again, not no-op.
    test "a repeat opt-out queues erasure again and keeps the original time" do
      enable_erasure()
      user = insert(:user, email: "again@example.com", external_id: nil)
      {:ok, first} = Engram.Accounts.set_analytics_opt_out(user)
      {:ok, second} = Engram.Accounts.set_analytics_opt_out(first)

      assert second.analytics_opt_out_at == first.analytics_opt_out_at
      assert length(all_enqueued(worker: PostHogErasure)) == 4
    end
  end

  describe "forget/1 misconfiguration" do
    test "logs an error when capture is on but erasure is not configured" do
      Application.delete_env(:engram, :posthog_erasure_api_key)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Analytics.forget(insert(:user, email: "m@example.com"))
        end)

      assert log =~ "erasure is not configured"
    end
  end
end
