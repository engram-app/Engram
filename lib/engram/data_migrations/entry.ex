defmodule Engram.DataMigrations.Entry do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:name, :string, autogenerate: false}
  schema "data_migrations" do
    field :version, :integer
    field :completed_at, :utc_datetime_usec
    field :opened_at, :utc_datetime_usec
    field :alerted_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
