defmodule Engram.Workers.PostHogPersonSyncTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Legal.TermsVersion
  alias Engram.Observability.PostHog
  alias Engram.Workers.PostHogPersonSync

  setup do
    prior_key = Application.get_env(:engram, :posthog_key)
    prior_host = Application.get_env(:engram, :posthog_host)

    on_exit(fn ->
      Application.put_env(:engram, :posthog_key, prior_key)
      Application.put_env(:engram, :posthog_host, prior_host)
    end)

    Engram.Legal.Seeder.seed()
    policy_effective_on(Date.add(Date.utc_today(), -1))
    :ok
  end

  defp policy_effective_on(date) do
    Repo.update_all(
      from(v in TermsVersion, where: v.document == "privacy_policy" and v.version == "2026-10-12"),
      [set: [effective_date: date]],
      skip_tenant_check: true
    )
  end

  defp enable_posthog do
    bypass = Bypass.open()
    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")
    bypass
  end

  defp capture_batch(bypass, status \\ 200) do
    parent = self()

    Bypass.expect(bypass, "POST", "/batch/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:batch, Jason.decode!(body)})
      Plug.Conn.resp(conn, status, "{}")
    end)
  end

  defp person(batch, email) do
    id = PostHog.analytics_id(email)
    Enum.find(batch["batch"], &(&1["distinct_id"] == id))
  end

  test "is a no-op when PostHog is not configured" do
    Application.delete_env(:engram, :posthog_key)
    insert(:user)

    assert :ok = perform_job(PostHogPersonSync, %{})
  end

  test "sends nothing before the privacy policy that announces it takes effect" do
    bypass = enable_posthog()
    Bypass.stub(bypass, "POST", "/batch/", fn _ -> flunk("sent before effective date") end)
    policy_effective_on(Date.add(Date.utc_today(), 1))
    insert(:user)

    assert :ok = perform_job(PostHogPersonSync, %{})
  end

  test "sets account properties on every live user in one batch" do
    bypass = enable_posthog()
    capture_batch(bypass)

    paid = insert(:user, email: "paid@example.com", display_name: "Pat")
    insert(:subscription, user: paid, tier: "pro", status: "active")
    vault = insert(:vault, user: paid)
    insert(:vault, user: paid)
    insert(:attachment, user: paid, vault: vault, size_bytes: 1_000)
    insert(:attachment, user: paid, vault: vault, size_bytes: 500)
    insert(:note, user: paid, vault: vault)
    insert(:note, user: paid, vault: vault)

    insert(:user, email: "free@example.com")

    assert :ok = perform_job(PostHogPersonSync, %{})
    assert_receive {:batch, batch}, 1_000

    assert batch["api_key"] == "phc_test_token"

    p = person(batch, "paid@example.com")
    assert p["event"] == "$set"
    set = p["properties"]["$set"]
    assert set["email"] == "paid@example.com"
    assert set["name"] == "Pat"
    assert set["plan"] == "pro"
    assert set["subscription_status"] == "active"
    assert set["vault_count"] == 2
    assert set["attachment_bytes"] == 1_500
    assert set["notes_count"] == 2
    assert is_binary(set["signed_up_at"])

    f = person(batch, "free@example.com")["properties"]["$set"]
    assert f["plan"] == "free"
    assert f["subscription_status"] == nil
    assert f["vault_count"] == 0
    assert f["attachment_bytes"] == 0
    assert f["notes_count"] == 0
  end

  test "counts only live notes and attachments in live vaults" do
    bypass = enable_posthog()
    capture_batch(bypass)

    u = insert(:user, email: "counts@example.com")
    live = insert(:vault, user: u)
    gone = insert(:vault, user: u, deleted_at: DateTime.utc_now(:second))

    insert(:note, user: u, vault: live)
    insert(:note, user: u, vault: live, deleted_at: DateTime.utc_now())
    insert(:note, user: u, vault: gone)
    insert(:attachment, user: u, vault: live, size_bytes: 10)
    insert(:attachment, user: u, vault: gone, size_bytes: 1_000)

    assert :ok = perform_job(PostHogPersonSync, %{})
    assert_receive {:batch, batch}, 1_000

    set = person(batch, "counts@example.com")["properties"]["$set"]
    assert set["notes_count"] == 1
    assert set["attachment_bytes"] == 10
    assert set["vault_count"] == 1
  end

  test "a lapsed paid subscription reads as free" do
    bypass = enable_posthog()
    capture_batch(bypass)

    u = insert(:user, email: "lapsed@example.com")
    insert(:subscription, user: u, tier: "pro", status: "canceled")

    assert :ok = perform_job(PostHogPersonSync, %{})
    assert_receive {:batch, batch}, 1_000

    set = person(batch, "lapsed@example.com")["properties"]["$set"]
    assert set["plan"] == "free"
    assert set["subscription_status"] == "canceled"
  end

  test "skips deleted and opted-out users and never sends note data" do
    bypass = enable_posthog()
    capture_batch(bypass)

    insert(:user, email: "gone@example.com", deleted_at: DateTime.utc_now())
    insert(:user, email: "objected@example.com", analytics_opt_out_at: DateTime.utc_now())
    live = insert(:user, email: "live@example.com")
    insert(:note, user: live, vault: insert(:vault, user: live))

    assert :ok = perform_job(PostHogPersonSync, %{})
    assert_receive {:batch, batch}, 1_000

    assert person(batch, "gone@example.com") == nil
    assert person(batch, "objected@example.com") == nil

    keys = person(batch, "live@example.com")["properties"]["$set"] |> Map.keys() |> Enum.sort()

    assert keys ==
             ~w(attachment_bytes email name notes_count plan signed_up_at subscription_status vault_count)
  end

  test "a rejected batch fails the job so Oban retries" do
    bypass = enable_posthog()
    capture_batch(bypass, 503)
    insert(:user)

    assert {:error, _} = perform_job(PostHogPersonSync, %{})
  end
end
