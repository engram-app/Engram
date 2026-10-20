defmodule Engram.Repo.Migrations.CreateCustomerInsightsTablesExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # Four tables created empty in this migration, so the two rules squawk
  # reports are moot: require-concurrent-index-creation (no rows, no writers)
  # and prefer-bigint-over-int. Same reasoning as note_revisions.
  #
  # phase/expand: new tables, no backfill. Customer insights (spec
  # 2026-10-19): our own copy of the analytics events, daily account and
  # vault snapshots, and the operator role grant log.
  #
  # NOT tenant tables (no RLS), like usage_meters: they hold counts and the
  # bounded analytics props, never note content, titles, paths or vault
  # names, and only the operator insights context and the snapshot job read
  # them. Every row about a user cascades with the account.
  def change do
    create table(:analytics_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      # NULL for an event attached to no person (`track_anonymous/2`).
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :event, :text, null: false
      add :props, :jsonb, null: false, default: "{}"
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:analytics_events, [:user_id, :inserted_at])
    create index(:analytics_events, [:event, :inserted_at])
    # The retention prune.
    create index(:analytics_events, [:inserted_at])

    create table(:user_daily_metrics, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), primary_key: true

      add :date, :date, primary_key: true
      # Account state when the snapshot ran. NULL on a day rebuilt from the
      # event log only (the job was down that day): state cannot be recovered.
      add :captured_at, :timestamptz
      add :plan, :text
      add :subscription_status, :text
      add :vault_count, :bigint
      add :notes, :bigint
      add :note_bytes, :bigint
      add :attachments, :bigint
      add :attachment_bytes, :bigint
      add :obsidian_devices, :bigint
      add :obsidian_last_seen_at, :timestamptz
      add :mcp_clients, {:array, :text}
      add :mcp_client_count, :bigint
      add :api_keys_live, :bigint
      add :api_keys_created, :bigint
      add :embed_tokens_used, :bigint
      add :embed_budget_pct, :float
      add :last_active_at, :timestamptz
      # Rolled up from analytics_events for the day.
      add :searches, :bigint, null: false, default: 0
      add :mcp_tool_calls, :jsonb, null: false, default: "{}"
      add :web_edited, :boolean, null: false, default: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:user_daily_metrics, [:date])

    create table(:vault_daily_metrics, primary_key: false) do
      add :vault_id, references(:vaults, type: :uuid, on_delete: :delete_all), primary_key: true

      add :date, :date, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :vault_created_at, :timestamptz
      add :notes, :bigint, null: false, default: 0
      add :note_bytes, :bigint, null: false, default: 0
      add :attachments, :bigint, null: false, default: 0
      add :attachment_bytes, :bigint, null: false, default: 0
      add :folders, :bigint, null: false, default: 0
      add :links, :bigint, null: false, default: 0
      add :tags, :bigint, null: false, default: 0
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
      add :updated_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:vault_daily_metrics, [:user_id])
    create index(:vault_daily_metrics, [:date])

    # Platform role grants (`Engram.Release.grant_operator/1`). Generic so
    # team roles can log here later with scope "org:<id>".
    create table(:role_change_log, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuidv7()")
      # NULL when granted from the release console (no acting user).
      add :actor_id, references(:users, type: :uuid, on_delete: :nilify_all)

      add :target_user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      add :action, :text, null: false
      add :scope, :text, null: false
      add :inserted_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:role_change_log, [:target_user_id])
    create index(:role_change_log, [:actor_id], where: "actor_id IS NOT NULL")

    # Explicit grants, as every create-table migration does (the default
    # privileges cover them where prepare_database ran). role_change_log is
    # append-only for the app.
    for table <- ~w(analytics_events user_daily_metrics vault_daily_metrics) do
      execute(
        "GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO engram_app",
        "REVOKE ALL ON #{table} FROM engram_app"
      )
    end

    execute(
      "GRANT SELECT, INSERT ON role_change_log TO engram_app",
      "REVOKE ALL ON role_change_log FROM engram_app"
    )
  end
end
