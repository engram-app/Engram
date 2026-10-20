defmodule Engram.Workers.DailySnapshotTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Analytics.Event
  alias Engram.Insights.UserDailyMetric
  alias Engram.Insights.VaultDailyMetric
  alias Engram.Links.NoteLink
  alias Engram.Workers.DailySnapshot

  defp yesterday, do: Date.add(Date.utc_today(), -1)
  defp days_ago(n), do: Date.add(Date.utc_today(), -n)

  defp at(date), do: DateTime.new!(date, ~T[12:00:00.000000], "Etc/UTC")

  defp event(user, name, props, date) do
    Repo.insert!(%Event{user_id: user.id, event: name, props: props, inserted_at: at(date)})
  end

  defp user_row(user, date \\ yesterday()),
    do: Repo.get_by(UserDailyMetric, user_id: user.id, date: date)

  defp link!(user, vault, note, position) do
    Repo.insert!(
      %NoteLink{
        user_id: user.id,
        vault_id: vault.id,
        source_note_id: note.id,
        target_text_ciphertext: "x",
        target_text_nonce: "n",
        target_basename_hmac: "h",
        link_type: "wikilink",
        position: position
      },
      skip_tenant_check: true
    )
  end

  test "snapshots each live user's account state for yesterday" do
    user = insert(:user)
    insert(:subscription, user: user, tier: "pro", status: "active")
    vault = insert(:vault, user: user)
    insert(:note, user: user, vault: vault)
    insert(:note, user: user, vault: vault)
    insert(:attachment, user: user, vault: vault, size_bytes: 700)
    insert(:api_key, user: user)
    event(user, "api_key_created", %{}, days_ago(30))
    event(user, "api_key_created", %{}, days_ago(20))

    assert :ok = perform_job(DailySnapshot, %{})

    row = user_row(user)
    assert %DateTime{} = row.captured_at
    assert row.plan == "pro"
    assert row.subscription_status == "active"
    assert row.vault_count == 1
    assert row.notes == 2
    assert row.note_bytes > 0
    assert row.attachments == 1
    assert row.attachment_bytes == 700
    assert row.api_keys_live == 1
    assert row.api_keys_created == 2
    assert row.mcp_clients == []
  end

  test "rolls up yesterday's searches, tool calls and web edits" do
    user = insert(:user)
    d = yesterday()
    event(user, "search_performed", %{"status" => "ok"}, d)
    event(user, "search_performed", %{"status" => "ok"}, d)
    event(user, "search_performed", %{"status" => "ok"}, Date.utc_today())
    event(user, "mcp_tool_called", %{"tool" => "search_notes", "calls" => 4}, d)
    event(user, "mcp_tool_called", %{"tool" => "search_notes", "calls" => 1}, d)
    event(user, "mcp_tool_called", %{"tool" => "get_notes", "calls" => 2}, d)
    # Counts the periodic flush sent on their own (Analytics.Folds).
    event(user, "mcp_tool_called_rollup", %{"tool" => "get_notes", "calls" => 3}, d)
    event(user, "surface_active", %{"surface" => "web", "client_type" => "web"}, d)

    assert :ok = perform_job(DailySnapshot, %{})

    row = user_row(user)
    assert row.searches == 2
    assert row.mcp_tool_calls == %{"search_notes" => 5, "get_notes" => 5}
    assert row.web_edited
  end

  test "browsing the web app is not a web edit" do
    user = insert(:user)
    event(user, "surface_active", %{"surface" => "web"}, yesterday())

    assert :ok = perform_job(DailySnapshot, %{})
    refute user_row(user).web_edited
  end

  test "the embed budget is the share of the user's bucket spent, override included" do
    free = insert(:user)
    comped = insert(:user)
    fresh = insert(:user)
    at = DateTime.utc_now()

    Repo.insert_all("usage_meters", [
      %{
        user_id: Ecto.UUID.dump!(free.id),
        lifetime_embed_tokens: 10_000_000,
        embed_bucket_tokens: 3_000_000.0,
        embed_bucket_at: at,
        notes_count: 0,
        updated_at: at
      },
      %{
        user_id: Ecto.UUID.dump!(comped.id),
        lifetime_embed_tokens: 10_000_000,
        embed_bucket_tokens: 30_000_000.0,
        embed_bucket_at: at,
        notes_count: 0,
        updated_at: at
      },
      # Spent the old lifetime allowance, never took from the bucket: full.
      %{
        user_id: Ecto.UUID.dump!(fresh.id),
        lifetime_embed_tokens: 19_000_000,
        notes_count: 0,
        updated_at: at
      }
    ])

    insert(:user_limit_override,
      user: comped,
      key: "embed_token_bucket",
      value: %{"v" => 40_000_000}
    )

    assert :ok = perform_job(DailySnapshot, %{})

    assert user_row(free).embed_tokens_used == 10_000_000
    assert user_row(free).embed_budget_pct == 50.0
    assert user_row(comped).embed_budget_pct == 25.0
    assert user_row(fresh).embed_budget_pct == 0.0
  end

  test "snapshots each live vault's size, by id only" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    folder = :crypto.strong_rand_bytes(32)
    n1 = insert(:note, user: user, vault: vault, folder_hmac: folder, tags_hmac: ["a", "b"])
    insert(:note, user: user, vault: vault, folder_hmac: folder, tags_hmac: ["b"])
    insert(:note, user: user, vault: vault, deleted_at: DateTime.utc_now())
    insert(:attachment, user: user, vault: vault, size_bytes: 10)
    link!(user, vault, n1, 0)
    link!(user, vault, n1, 1)
    gone = insert(:vault, user: user, deleted_at: DateTime.utc_now(:second))

    assert :ok = perform_job(DailySnapshot, %{})

    row = Repo.get_by(VaultDailyMetric, vault_id: vault.id, date: yesterday())
    assert row.user_id == user.id
    assert row.notes == 2
    assert row.attachments == 1
    assert row.attachment_bytes == 10
    assert row.folders == 1
    assert row.tags == 2
    assert row.links == 2
    assert %DateTime{} = row.vault_created_at
    refute Repo.get_by(VaultDailyMetric, vault_id: gone.id)
  end

  test "snapshots vaults in chunks, each chunk its own query" do
    user = insert(:user)
    vaults = for _ <- 1..3, do: insert(:vault, user: user)

    assert %{vaults: 3} = Engram.Insights.Snapshot.run(chunk: 1)

    for v <- vaults, do: assert(Repo.get_by(VaultDailyMetric, vault_id: v.id, date: yesterday()))
  end

  # A retry of a job that timed out half way keeps the chunks it already
  # wrote and does the rest, so the day is not lost to a timeout.
  test "a retry resumes: vaults this job already wrote are not redone" do
    user = insert(:user)
    done = insert(:vault, user: user)
    todo = insert(:vault, user: user)
    insert(:note, user: user, vault: done)
    inserted_at = DateTime.add(DateTime.utc_now(), -60, :second)

    Repo.insert!(
      %VaultDailyMetric{vault_id: done.id, user_id: user.id, date: yesterday(), notes: 99},
      skip_tenant_check: true
    )

    job = build_job(DailySnapshot, %{}) |> Map.put(:inserted_at, inserted_at)
    assert :ok = perform_job(job)

    assert Repo.get_by(VaultDailyMetric, vault_id: done.id, date: yesterday()).notes == 99
    assert Repo.get_by(VaultDailyMetric, vault_id: todo.id, date: yesterday())

    # A new job (a manual rerun) rewrites every vault.
    assert :ok = perform_job(DailySnapshot, %{})
    assert Repo.get_by(VaultDailyMetric, vault_id: done.id, date: yesterday()).notes == 1
  end

  test "writes the day before the job was inserted, even when it runs later" do
    user = insert(:user)
    insert(:vault, user: user)
    inserted_at = DateTime.add(DateTime.utc_now(), -1, :day)

    job = build_job(DailySnapshot, %{}) |> Map.put(:inserted_at, inserted_at)
    assert :ok = perform_job(job)

    assert user_row(user, days_ago(2))
    refute user_row(user, yesterday())
  end

  test "skips users who opted out of analytics and deleted users" do
    opted = insert(:user, analytics_opt_out_at: DateTime.utc_now())
    insert(:vault, user: opted)
    deleted = insert(:user, deleted_at: DateTime.utc_now())

    assert :ok = perform_job(DailySnapshot, %{})

    refute user_row(opted)
    refute user_row(deleted)
    assert Repo.aggregate(VaultDailyMetric, :count) == 0
  end

  test "is idempotent: a second run updates the same rows" do
    user = insert(:user)
    vault = insert(:vault, user: user)

    assert :ok = perform_job(DailySnapshot, %{})
    insert(:note, user: user, vault: vault)
    assert :ok = perform_job(DailySnapshot, %{})

    assert Repo.aggregate(UserDailyMetric, :count) == 1
    assert Repo.aggregate(VaultDailyMetric, :count) == 1
    assert user_row(user).notes == 1
  end

  test "heals the activity of missed days and keeps their captured state" do
    user = insert(:user)
    missed = days_ago(3)
    captured = days_ago(4)

    Repo.insert!(%UserDailyMetric{
      user_id: user.id,
      date: captured,
      plan: "free",
      captured_at: at(captured)
    })

    event(user, "search_performed", %{}, missed)
    event(user, "search_performed", %{}, captured)
    event(user, "search_performed", %{}, days_ago(30))

    assert :ok = perform_job(DailySnapshot, %{})

    healed = user_row(user, missed)
    assert healed.searches == 1
    assert healed.captured_at == nil
    assert healed.plan == nil

    kept = user_row(user, captured)
    assert kept.plan == "free"
    assert kept.searches == 1
    refute user_row(user, days_ago(30))
  end
end
