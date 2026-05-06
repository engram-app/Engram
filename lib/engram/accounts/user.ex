defmodule Engram.Accounts.User do
  use Ecto.Schema

  schema "users" do
    field :email, :string
    field :external_id, :string
    field :password_hash, :string
    field :role, :string, default: "member"
    field :display_name, :string
    field :encrypted_dek, :binary
    field :dek_version, :integer, default: 1
    field :key_provider, :string, default: "local"

    belongs_to :plan, Engram.Billing.Plan
    has_many :notes, Engram.Notes.Note
    has_many :api_keys, Engram.Accounts.ApiKey
    has_many :vaults, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
