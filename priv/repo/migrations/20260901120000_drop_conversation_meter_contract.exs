defmodule Engram.Repo.Migrations.DropConversationMeterContract do
  use Ecto.Migration

  @moduledoc """
  Contract step for the AI-metering collapse.

  Six `usage_meters` columns backed `Engram.ConversationMeter`, which metered
  every MCP tool call in a 30-minute-window unit that corresponded to nothing a
  user does. `usage_buckets` backed `Engram.Usage.DailyCap`, the Postgres token
  bucket the search caps spent. Both are deleted: `ai_searches_per_day` is
  counted in `EngramWeb.RateLimiter`, the same cluster-synced ETS counter the
  rate limiter uses, so the request path touches no database at all.

  No backfill: nothing reads these, and any DB is wipeable pre-launch.
  """

  def up do
    alter table(:usage_meters) do
      remove :active_conversation_started_at
      remove :active_conversation_query_count
      remove :conversations_today
      remove :conversations_day_key
      remove :queries_today
      remove :queries_day_key
    end

    drop table(:usage_buckets)
  end

  def down do
    alter table(:usage_meters) do
      add :active_conversation_started_at, :utc_datetime_usec
      add :active_conversation_query_count, :integer, default: 0
      add :conversations_today, :integer, default: 0
      add :conversations_day_key, :date
      add :queries_today, :integer, default: 0
      add :queries_day_key, :date
    end

    create table(:usage_buckets, primary_key: false) do
      add :user_id, :uuid, null: false
      add :kind, :string, null: false
      add :tokens, :float, null: false
      add :last_refill_at, :utc_datetime_usec, null: false
    end

    create unique_index(:usage_buckets, [:user_id, :kind])
  end
end
