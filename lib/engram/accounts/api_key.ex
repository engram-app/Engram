defmodule Engram.Accounts.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "api_keys" do
    field :key_hash, :string
    field :name, :string
    field :last_used, :utc_datetime

    belongs_to :user, Engram.Accounts.User
    many_to_many :vaults, Engram.Vaults.Vault, join_through: "api_key_vaults"

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:key_hash, :name, :user_id])
    |> validate_required([:key_hash, :user_id])
  end
end
