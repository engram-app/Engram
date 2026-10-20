defmodule Engram.Analytics.Event do
  @moduledoc """
  One `Engram.Analytics` event, our own copy of what PostHog receives
  (`analytics_events`). Throttled, skipped on opt-out and pruned after two
  years, so it is NOT an audit log. `user_id` is nil for an anonymous event.
  """
  use Engram.Schema

  schema "analytics_events" do
    field :user_id, Ecto.UUID
    field :event, :string
    field :props, :map, default: %{}
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
