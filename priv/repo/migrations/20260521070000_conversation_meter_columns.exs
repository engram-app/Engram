defmodule Engram.Repo.Migrations.ConversationMeterColumns do
  use Ecto.Migration

  # Pricing v2 §D — conversation gaming defense. Extends usage_meters with
  # per-user counters that drive the rotate-on-cap logic:
  #
  #   - active_conversation_started_at    — when current conversation began
  #   - active_conversation_query_count   — queries in current conversation
  #   - conversations_today               — conversations counted today
  #   - conversations_day_key             — date for the conversations_today
  #                                         counter (auto-rolls at UTC day flip)
  #   - queries_today                     — total queries today (for the
  #                                         ai_queries_per_day cap at Pro tier)
  #   - queries_day_key                   — date for queries_today
  def change do
    alter table(:usage_meters) do
      add :active_conversation_started_at, :utc_datetime_usec
      add :active_conversation_query_count, :integer, null: false, default: 0
      add :conversations_today, :integer, null: false, default: 0
      add :conversations_day_key, :date
      add :queries_today, :integer, null: false, default: 0
      add :queries_day_key, :date
    end
  end
end
