defmodule Engram.Logs.ClientLog do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  schema "client_logs" do
    field :ts, :utc_datetime
    field :level, :string, default: "info"
    field :category, :string, default: ""
    field :message, :string, default: ""
    field :stack, :string
    field :plugin_version, :string, default: ""
    field :platform, :string, default: ""

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :ts,
      :level,
      :category,
      :message,
      :stack,
      :plugin_version,
      :platform,
      :user_id
    ])
    |> validate_required([:ts, :user_id])
  end
end
