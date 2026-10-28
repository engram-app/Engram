defmodule Engram.Workers.PersonOriginSyncTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Auth.Clerk.ApiMock
  alias Engram.Legal.TermsVersion
  alias Engram.Observability.PostHog
  alias Engram.Workers.PersonOriginSync

  setup :verify_on_exit!

  setup do
    keys = [
      :person_origin_pause_ms,
      :posthog_key,
      :posthog_host,
      :posthog_erasure_api_key,
      :posthog_project_id
    ]

    prior = Map.new(keys, &{&1, Application.get_env(:engram, &1)})
    on_exit(fn -> Enum.each(prior, fn {k, v} -> Application.put_env(:engram, k, v) end) end)

    Application.put_env(:engram, :person_origin_pause_ms, 0)
    bypass = Bypass.open()
    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")
    Application.put_env(:engram, :posthog_erasure_api_key, "phx_test")
    Application.put_env(:engram, :posthog_project_id, "1")

    Engram.Legal.Seeder.seed()
    policy_effective_on(Date.add(Date.utc_today(), -1))
    {:ok, bypass: bypass}
  end

  defp policy_effective_on(date) do
    Repo.update_all(
      from(v in TermsVersion, where: v.document == "privacy_policy" and v.version == "2026-10-12"),
      [set: [effective_date: date]],
      skip_tenant_check: true
    )
  end

  # The persons lookup returns `props`; `$set` batches are sent to the test.
  defp posthog(bypass, props) do
    parent = self()

    Bypass.stub(bypass, "GET", "/api/projects/1/persons/", fn conn ->
      body = Jason.encode!(%{results: [%{id: "p1", properties: props}]})

      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, body)
    end)

    Bypass.stub(bypass, "POST", "/batch/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:batch, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, "{}")
    end)
  end

  defp set_for(email) do
    id = PostHog.analytics_id(email)
    assert_receive {:batch, %{"batch" => batch}}, 1_000
    Enum.find(batch, &(&1["distinct_id"] == id))["properties"]["$set"]
  end

  test "Clerk wins country and device; app locale wins language", %{bypass: bypass} do
    posthog(bypass, %{"$browser_language" => "en-US", "$initial_device_type" => "Desktop"})
    user = insert(:user, email: "a@example.com", external_id: "user_a", locale: "pt-BR")

    expect(ApiMock, :latest_activity, fn "user_a" ->
      {:ok, %{country: "BR", device_type: "mobile"}}
    end)

    assert :ok = perform_job(PersonOriginSync, %{"user_id" => user.id})
    set = set_for("a@example.com")

    assert %{"country" => "BR", "country_source" => "clerk"} = set
    assert %{"language" => "pt-BR", "language_source" => "app_locale"} = set
    assert %{"device_type" => "mobile", "device_type_source" => "clerk"} = set
  end

  test "missing Clerk and locale fall back to PostHog first-event values", %{bypass: bypass} do
    posthog(bypass, %{"$browser_language" => "ru", "$initial_device_type" => "Tablet"})
    user = insert(:user, email: "b@example.com", external_id: "user_b", locale: nil)
    expect(ApiMock, :latest_activity, fn _ -> {:ok, nil} end)

    assert :ok = perform_job(PersonOriginSync, %{"user_id" => user.id})
    set = set_for("b@example.com")

    refute Map.has_key?(set, "country")
    assert %{"language" => "ru", "language_source" => "browser_language"} = set
    assert %{"device_type" => "tablet", "device_type_source" => "posthog_initial"} = set
  end

  test "does not overwrite a stored Clerk device type with a lower source", %{bypass: bypass} do
    posthog(bypass, %{"device_type_source" => "clerk", "$initial_device_type" => "Desktop"})
    user = insert(:user, email: "c@example.com", external_id: "user_c", locale: "en")
    expect(ApiMock, :latest_activity, fn _ -> {:ok, nil} end)

    assert :ok = perform_job(PersonOriginSync, %{"user_id" => user.id})
    refute Map.has_key?(set_for("c@example.com"), "device_type")
  end

  test "an opted-out user is never read or sent", %{bypass: bypass} do
    Bypass.stub(bypass, "POST", "/batch/", fn _ -> flunk("sent for opted-out user") end)
    user = insert(:user, external_id: "user_d", analytics_opt_out_at: DateTime.utc_now())

    assert :ok = perform_job(PersonOriginSync, %{"user_id" => user.id})
  end

  test "before the effective date country and language still send, but never email or name",
       %{bypass: bypass} do
    posthog(bypass, %{})
    policy_effective_on(Date.add(Date.utc_today(), 1))
    user = insert(:user, email: "e@example.com", external_id: "user_e", locale: "de")
    expect(ApiMock, :latest_activity, fn _ -> {:ok, %{country: "DE", device_type: nil}} end)

    assert :ok = perform_job(PersonOriginSync, %{"user_id" => user.id})
    set = set_for("e@example.com")
    assert set["country"] == "DE"
    assert set["language"] == "de"
    refute Map.has_key?(set, "email")
    refute Map.has_key?(set, "name")
  end

  test "backfill covers Clerk users only", %{bypass: bypass} do
    posthog(bypass, %{})
    insert(:user, email: "f@example.com", external_id: "user_f", locale: "ja")
    insert(:user, email: "selfhost@example.com", external_id: nil)

    expect(ApiMock, :latest_activity, 1, fn "user_f" ->
      {:ok, %{country: "JP", device_type: nil}}
    end)

    assert :ok = perform_job(PersonOriginSync, %{"backfill" => true})
    assert set_for("f@example.com")["country"] == "JP"
  end

  test "a failed PostHog read writes nothing and returns an error for Oban to retry", %{
    bypass: bypass
  } do
    Bypass.stub(bypass, "GET", "/api/projects/1/persons/", &Plug.Conn.resp(&1, 429, "{}"))
    Bypass.stub(bypass, "POST", "/batch/", fn _ -> flunk("wrote without the stored sources") end)
    user = insert(:user, email: "g@example.com", external_id: "user_g", locale: "en")

    assert {:error, {:http_error, 429}} =
             perform_job(PersonOriginSync, %{"user_id" => user.id})
  end

  test "a failed Clerk read writes nothing and returns an error", %{bypass: bypass} do
    posthog(bypass, %{})
    Bypass.stub(bypass, "POST", "/batch/", fn _ -> flunk("wrote after a Clerk failure") end)
    user = insert(:user, email: "h@example.com", external_id: "user_h", locale: "en")
    expect(ApiMock, :latest_activity, fn _ -> {:error, {:http_error, 429}} end)

    assert {:error, {:http_error, 429}} =
             perform_job(PersonOriginSync, %{"user_id" => user.id})
  end

  test "skips quietly (no error, no retry storm) when person reads are not configured", %{
    bypass: bypass
  } do
    Application.delete_env(:engram, :posthog_erasure_api_key)
    Bypass.stub(bypass, "POST", "/batch/", fn _ -> flunk("wrote without read config") end)
    user = insert(:user, external_id: "user_j", locale: "en")

    assert :ok = perform_job(PersonOriginSync, %{"user_id" => user.id})
    assert :ok = perform_job(PersonOriginSync, %{"backfill" => true})
    refute_enqueued(worker: PersonOriginSync)
  end

  test "backfill defers failed users to single retries and still chains", %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/api/projects/1/persons/", &Plug.Conn.resp(&1, 429, "{}"))
    Bypass.stub(bypass, "POST", "/batch/", fn _ -> flunk("nothing resolved, nothing written") end)

    for n <- 1..100,
        do: insert(:user, email: "d#{n}@example.com", external_id: "d#{n}", locale: "fr")

    assert :ok = perform_job(PersonOriginSync, %{"backfill" => true})

    jobs = all_enqueued(worker: PersonOriginSync)
    assert Enum.count(jobs, &Map.has_key?(&1.args, "user_id")) == 100
    assert Enum.count(jobs, &(&1.args["backfill"] == true and &1.args["after"])) == 1
  end

  test "a user soft-deleted before the job runs is not sent", %{bypass: bypass} do
    Bypass.stub(bypass, "POST", "/batch/", fn _ -> flunk("sent for a deleted user") end)

    user =
      insert(:user, external_id: "user_i", locale: "en", deleted_at: DateTime.utc_now(:second))

    assert :ok = perform_job(PersonOriginSync, %{"user_id" => user.id})
  end

  describe "backfill batching" do
    setup %{bypass: bypass} do
      posthog(bypass, %{})
      stub(ApiMock, :latest_activity, fn _ -> {:ok, nil} end)
      :ok
    end

    test "resumes after the cursor, in one /batch write" do
      [first | rest] =
        for(
          n <- 1..3,
          do: insert(:user, email: "u#{n}@example.com", external_id: "c#{n}", locale: "fr")
        )
        |> Enum.sort_by(& &1.id)

      assert :ok = perform_job(PersonOriginSync, %{"backfill" => true, "after" => first.id})
      assert_receive {:batch, %{"batch" => sent}}, 1_000
      assert length(sent) == length(rest)
      refute_receive {:batch, _}, 100
    end

    test "a failed successor insert fails the batch instead of ending the chain" do
      for n <- 1..100,
          do: insert(:user, email: "x#{n}@example.com", external_id: "x#{n}", locale: "fr")

      # DDL rolls back with the sandbox transaction.
      Repo.query!(
        "ALTER TABLE oban_jobs ADD CONSTRAINT no_successor CHECK (NOT (args ? 'after'))"
      )

      assert_raise Postgrex.Error, fn ->
        perform_job(PersonOriginSync, %{"backfill" => true})
      end
    end

    test "a retried batch does not fork the chain" do
      for n <- 1..100,
          do: insert(:user, email: "y#{n}@example.com", external_id: "y#{n}", locale: "fr")

      assert :ok = perform_job(PersonOriginSync, %{"backfill" => true})
      assert :ok = perform_job(PersonOriginSync, %{"backfill" => true})

      assert Enum.count(all_enqueued(worker: PersonOriginSync), & &1.args["after"]) == 1
    end

    test "a full batch chains the next one from the last id" do
      for n <- 1..100,
          do: insert(:user, email: "b#{n}@example.com", external_id: "b#{n}", locale: "fr")

      assert :ok = perform_job(PersonOriginSync, %{"backfill" => true})
      assert_receive {:batch, %{"batch" => sent}}, 5_000
      assert length(sent) == 100

      assert [%{args: %{"backfill" => true, "after" => _}}] =
               all_enqueued(worker: PersonOriginSync)
    end
  end

  test "enqueue_user dedupes a redelivered webhook" do
    id = Ecto.UUID.generate()
    assert {:ok, %{conflict?: false}} = PersonOriginSync.enqueue_user(id)
    assert {:ok, %{conflict?: true}} = PersonOriginSync.enqueue_user(id)
  end
end
