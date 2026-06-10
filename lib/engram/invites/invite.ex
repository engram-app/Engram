defmodule Engram.Invites.Invite do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  schema "invites" do
    field :token_hash, :string, redact: true
    field :created_by, :id
    field :label, :string
    field :max_uses, :integer, default: 1
    field :use_count, :integer, default: 0
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:token_hash, :created_by, :label, :max_uses, :expires_at])
    |> validate_required([:token_hash, :created_by, :max_uses])
    |> validate_number(:max_uses, greater_than: 0)
  end
end
