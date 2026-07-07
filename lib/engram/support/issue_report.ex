defmodule Engram.Support.IssueReport do
  use Ecto.Schema
  import Ecto.Changeset

  # autogenerate: true so Ecto sets id client-side and returns it in the struct
  # (the migration's uuidv7() default is a raw-insert fallback). Matches
  # oauth/client.ex convention.
  @primary_key {:id, :binary_id, autogenerate: true}
  @surfaces ~w(plugin web)

  schema "issue_reports" do
    field :user_id, :binary_id
    field :vault_id, :string
    field :surface, :string
    field :app_version, :string
    field :device_fingerprint, :string
    field :description, :string
    field :status, :string, default: "open"
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @cast ~w(user_id vault_id surface app_version device_fingerprint description status)a
  @required ~w(user_id surface description)a

  def changeset(report, attrs) do
    report
    |> cast(attrs, @cast)
    |> validate_required(@required)
    |> validate_inclusion(:surface, @surfaces)
    |> validate_length(:description, min: 1, max: 5000)
  end
end
