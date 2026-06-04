defmodule Engram.Auth.DeviceAuthorization do
  use Ecto.Schema
  import Ecto.Changeset

  schema "device_authorizations" do
    field :device_code, :string
    field :user_code, :string
    field :client_id, :string
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    field :vault_name, :string

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault
    belongs_to :viewer_user, Engram.Accounts.User, foreign_key: :viewer_user_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(auth, attrs) do
    auth
    |> cast(attrs, [:device_code, :user_code, :client_id, :status, :expires_at, :vault_name])
    |> validate_required([:device_code, :user_code, :client_id, :status, :expires_at])
    |> validate_length(:vault_name, max: 100)
    |> validate_inclusion(:status, ~w(pending authorized consumed expired))
    |> unique_constraint(:device_code)
    |> unique_constraint(:user_code)
  end

  def authorize_changeset(auth, attrs) do
    auth
    |> cast(attrs, [:user_id, :vault_id, :status])
    |> validate_required([:user_id, :vault_id, :status])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:vault_id)
  end
end
