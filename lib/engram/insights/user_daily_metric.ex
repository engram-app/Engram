defmodule Engram.Insights.UserDailyMetric do
  @moduledoc "One account's state and activity on one day (`Engram.Workers.DailySnapshot`)."
  use Ecto.Schema

  @primary_key false
  @foreign_key_type Ecto.UUID

  schema "user_daily_metrics" do
    field :user_id, Ecto.UUID, primary_key: true
    field :date, :date, primary_key: true
    field :captured_at, :utc_datetime_usec
    field :plan, :string
    field :subscription_status, :string
    field :vault_count, :integer
    field :notes, :integer
    field :note_bytes, :integer
    field :attachments, :integer
    field :attachment_bytes, :integer
    field :obsidian_devices, :integer
    field :obsidian_last_seen_at, :utc_datetime_usec
    field :mcp_clients, {:array, :string}
    field :mcp_client_count, :integer
    field :api_keys_live, :integer
    field :api_keys_created, :integer
    field :embed_tokens_used, :integer
    field :embed_budget_pct, :float
    field :last_active_at, :utc_datetime_usec
    field :searches, :integer, default: 0
    field :mcp_tool_calls, :map, default: %{}
    field :web_edited, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end
end
