defmodule Engram.Idempotency.Key do
  @moduledoc false
  use Engram.Schema

  schema "idempotency_keys" do
    field :key, Ecto.UUID
    field :status, :integer
    field :response_ciphertext, :binary
    field :response_nonce, :binary
    field :expires_at, :utc_datetime_usec

    belongs_to :user, Engram.Accounts.User

    timestamps(type: :utc_datetime_usec, inserted_at: :inserted_at, updated_at: false)
  end
end
