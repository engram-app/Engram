defmodule Engram.Accounts.User do
  use Ecto.Schema

  # T3.0.5 — Allowlist serialization. Anything not listed is invisible to
  # Jason.encode!/1 even if a future controller does `json(conn, %{user: user})`.
  @derive {Jason.Encoder, only: [:id, :email, :role, :display_name, :created_at, :updated_at]}

  schema "users" do
    field :email, :string
    field :external_id, :string
    field :password_hash, :string, redact: true
    field :role, :string, default: "member"
    field :display_name, :string
    field :encrypted_dek, :binary, redact: true
    field :dek_version, :integer, default: 1, redact: true
    field :key_provider, :string, default: "local", redact: true
    field :dek_rotation_locked_at, :utc_datetime_usec

    belongs_to :plan, Engram.Billing.Plan
    has_many :notes, Engram.Notes.Note
    has_many :api_keys, Engram.Accounts.ApiKey
    has_many :vaults, Engram.Vaults.Vault

    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
