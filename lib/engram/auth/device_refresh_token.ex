defmodule Engram.Auth.DeviceRefreshToken do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  schema "device_refresh_tokens" do
    field :token_hash, :string
    field :family_id, Ecto.UUID
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :family_id, :user_id, :vault_id, :expires_at])
    |> validate_required([:token_hash, :family_id, :user_id, :vault_id, :expires_at])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:vault_id)
  end
end
