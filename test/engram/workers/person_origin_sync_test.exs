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
    keys = [:posthog_key, :posthog_host, :posthog_erasure_api_key, :posthog_project_id]
    prior = Map.new(keys, &{&1, Application.get_env(:engram, &1)})
    on_exit(fn -> Enum.each(prior, fn {k, v} -> Application.put_env(:engram, k, v) end) end)

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
      Plug.Conn.resp(conn, 200, body)
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
    expect(ApiMock, :latest_activity, fn _ -> {:error, :boom} end)

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

  test "sends nothing before the privacy policy takes effect", %{bypass: bypass} do
    policy_effective_on(Date.add(Date.utc_today(), 1))
    Bypass.stub(bypass, "POST", "/batch/", fn _ -> flunk("sent before effective date") end)
    user = insert(:user, external_id: "user_e")

    assert :ok = perform_job(PersonOriginSync, %{"user_id" => user.id})
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
end
