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
    assert set["total_attachment_bytes"] == 1_500
    assert set["total_notes"] == 2
    assert is_binary(set["signed_up_at"])

    f = person(batch, "free@example.com")["properties"]["$set"]
    assert f["plan"] == "free"
    assert f["subscription_status"] == nil
    assert f["vault_count"] == 0
    assert f["total_attachment_bytes"] == 0
    assert f["total_notes"] == 0
    assert f["obsidian_devices"] == 0
    assert f["mcp_clients"] == []
    assert f["api_keys_count"] == 0
    assert f["embed_tokens_used"] == 0
    assert f["first_vault_at"] == nil
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
    assert set["total_notes"] == 1
    assert set["total_attachment_bytes"] == 10
    assert set["vault_count"] == 1
  end

  test "sizes the largest live vault by notes and by bytes" do
    bypass = enable_posthog()
    capture_batch(bypass)

    u = insert(:user, email: "sizes@example.com")
    many = insert(:vault, user: u)
    heavy = insert(:vault, user: u)
    for _ <- 1..3, do: insert(:note, user: u, vault: many, content_ciphertext: "ab")
    insert(:note, user: u, vault: heavy, content_ciphertext: "abcdef")
    insert(:attachment, user: u, vault: heavy, size_bytes: 100)

    assert :ok = perform_job(PostHogPersonSync, %{})
    assert_receive {:batch, batch}, 1_000

    set = person(batch, "sizes@example.com")["properties"]["$set"]
    assert set["total_notes"] == 4
    assert set["total_note_bytes"] == 12
    assert set["largest_vault_notes"] == 3
    assert set["largest_vault_bytes"] == 106
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
             ~w(ai_connected_at api_keys_count email embed_tokens_used first_vault_at
                largest_vault_bytes largest_vault_notes last_active_at mcp_client_count mcp_clients
                name obsidian_devices obsidian_last_seen_at plan plugin_connected_at signed_up_at
                subscription_status total_attachment_bytes total_attachments total_note_bytes
                total_notes vault_count)
  end

  test "sets connection, usage and milestone properties" do
    bypass = enable_posthog()
    capture_batch(bypass)

    u = insert(:user, email: "rich@example.com")
    vault = insert(:vault, user: u, created_at: ~U[2026-09-01 10:00:00Z])
    insert(:vault, user: u, created_at: ~U[2026-09-05 10:00:00Z])
    insert(:note, user: u, vault: vault, content_ciphertext: :binary.copy("x", 40))
    insert(:attachment, user: u, vault: vault, size_bytes: 1)
    insert(:attachment, user: u, vault: vault, size_bytes: 1)

    insert(:api_key, user: u)

    # Two live device families (one rotated twice) and one revoked.
    family = Ecto.UUID.generate()
    insert(:device_refresh_token, user: u, vault: vault, family_id: family)
    insert(:device_refresh_token, user: u, vault: vault, family_id: family)
    insert(:device_refresh_token, user: u, vault: vault)
    insert(:device_refresh_token, user: u, vault: vault, revoked_at: DateTime.utc_now(:second))

    # MCP grants bucket to their client family; a revoked one does not count.
    claude = insert(:oauth_client, client_name: "Claude Desktop")
    cursor = insert(:oauth_client, client_name: "Cursor")
    gone = insert(:oauth_client, client_name: "ChatGPT")
    insert(:oauth_refresh_token, user_id: u.id, client_id: claude.client_id)
    insert(:oauth_refresh_token, user_id: u.id, client_id: cursor.client_id)

    insert(:oauth_refresh_token,
      user_id: u.id,
      client_id: gone.client_id,
      revoked_at: DateTime.utc_now(:second)
    )

    Repo.insert_all(
      "usage_meters",
      [
        %{
          user_id: Ecto.UUID.dump!(u.id),
          lifetime_embed_tokens: 1234,
          notes_count: 1,
          last_active_at: ~U[2026-10-01 12:00:00.000000Z],
          updated_at: DateTime.utc_now()
        }
      ],
      skip_tenant_check: true
    )

    for {action, at} <- [
          {"plugin_connected", ~U[2026-09-02 10:00:00.000000Z]},
          {"ai_connected", ~U[2026-09-03 10:00:00.000000Z]}
        ] do
      Repo.insert!(%Engram.Onboarding.Action{user_id: u.id, action: action, inserted_at: at},
        skip_tenant_check: true
      )
    end

    assert :ok = perform_job(PostHogPersonSync, %{})
    assert_receive {:batch, batch}, 1_000

    set = person(batch, "rich@example.com")["properties"]["$set"]
    assert set["total_attachments"] == 2
    assert set["total_note_bytes"] == 40
    assert set["api_keys_count"] == 1
    assert set["obsidian_devices"] == 2
    assert set["mcp_clients"] == ["claude", "cursor"]
    assert set["mcp_client_count"] == 2
    assert is_binary(set["obsidian_last_seen_at"])
    assert set["embed_tokens_used"] == 1234
    assert set["last_active_at"] =~ "2026-10-01T12:00:00"
    assert set["first_vault_at"] =~ "2026-09-01T10:00:00"
    assert set["plugin_connected_at"] =~ "2026-09-02T10:00:00"
    assert set["ai_connected_at"] =~ "2026-09-03T10:00:00"
  end

  test "a rejected batch fails the job so Oban retries" do
    bypass = enable_posthog()
    capture_batch(bypass, 503)
    insert(:user)

    assert {:error, _} = perform_job(PostHogPersonSync, %{})
  end
end
