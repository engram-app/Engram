defmodule Engram.Accounts.ApiKey do
  @moduledoc false
  use Engram.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "api_keys" do
    field :key_hash, :string
    field :name, :string, redact: true
    field :last_used, :utc_datetime
    # Level for every vault without an `api_key_vaults` row (#332), including
    # vaults created later. NULL = a pre-levels key: no rows means every vault.
    field :default_access, :string

    belongs_to :user, Engram.Accounts.User
    many_to_many :vaults, Engram.Vaults.Vault, join_through: "api_key_vaults"

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:key_hash, :name, :user_id, :default_access])
    |> validate_required([:key_hash, :user_id])
  end
end
