defmodule Engram.Logs.ClientLog do
  @moduledoc """
  Schema for ingested plugin debug logs.

  Deliberately has NO changeset. The one write path (`Engram.Logs.insert_logs/2`)
  builds raw maps and calls `Repo.insert_all/3`, which bypasses changesets
  entirely — so the `changeset/2` that used to live here never ran on any live
  path. It read as protection that was not wired up, which is worse than none:
  the next person to touch this would reasonably assume its cast list and
  `validate_required` were enforcing something.

  Field bounds are applied in `Engram.Logs.insert_logs/2` instead, next to the
  batch cap and the existing read limit.
  """
  use Engram.Schema

  schema "client_logs" do
    field :ts, :utc_datetime
    field :level, :string, default: "info"
    field :category, :string, default: ""
    field :message, :string, default: ""
    field :stack, :string
    field :plugin_version, :string, default: ""
    field :platform, :string, default: ""
    field :conn_id, :string
    field :device_id, :string

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end
end
