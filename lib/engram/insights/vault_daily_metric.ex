defmodule Engram.Insights.VaultDailyMetric do
  @moduledoc "One vault's size on one day. Vault id only, never its name."
  use Ecto.Schema

  @primary_key false

  schema "vault_daily_metrics" do
    field :vault_id, Ecto.UUID, primary_key: true
    field :date, :date, primary_key: true
    field :user_id, Ecto.UUID
    field :vault_created_at, :utc_datetime_usec
    field :notes, :integer, default: 0
    field :note_bytes, :integer, default: 0
    field :attachments, :integer, default: 0
    field :attachment_bytes, :integer, default: 0
    field :folders, :integer, default: 0
    field :links, :integer, default: 0
    field :tags, :integer, default: 0
    # The vault's seq when the sizes were read, and the day they last were:
    # an unchanged vault is copied from the day before (Insights.Snapshot).
    field :change_seq, :integer
    field :scanned_on, :date
    timestamps(type: :utc_datetime_usec)
  end
end
