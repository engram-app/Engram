defmodule Engram.Auth.RefreshToken do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  schema "refresh_tokens" do
    belongs_to :user, Engram.Accounts.User
    field :token_hash, :string
    field :family_id, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false, inserted_at: :created_at)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :token_hash, :family_id, :expires_at])
    |> validate_required([:user_id, :token_hash, :family_id, :expires_at])
  end
end
