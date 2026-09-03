defmodule Engram.OAuth.AuthorizationCode do
  @moduledoc """
  Short-lived (10-minute) authorization code minted at `/oauth/authorize`
  consent. Consumed at `/oauth/token` (Phase 4) when the client redeems
  it for an access + refresh token. PKCE binds the code to the client
  that initiated the flow — `code_challenge` is stored at mint time, the
  client sends `code_verifier` at exchange time.
  """
  use Engram.Schema
  import Ecto.Changeset

  schema "oauth_authorization_codes" do
    field :code_hash, :string
    field :client_id, :binary_id
    field :user_id, Ecto.UUID
    field :redirect_uri, :string
    field :code_challenge, :string
    field :code_challenge_method, :string, default: "S256"
    field :scope, :string
    field :vault_id, Ecto.UUID
    # Multi-vault grants. NULL = all vaults (including ones created later).
    # A non-empty list = exactly that set. `vault_id` is dual-written for
    # single-vault grants until the phase/contract release drops it.
    field :vault_ids, {:array, Ecto.UUID}
    field :state, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @cast_fields ~w(code_hash client_id user_id redirect_uri code_challenge
                  code_challenge_method scope vault_id vault_ids state expires_at)a
  @required ~w(code_hash client_id user_id redirect_uri code_challenge
               code_challenge_method expires_at)a

  def changeset(code, attrs) do
    code
    |> cast(attrs, @cast_fields)
    |> validate_required(@required)
    |> unique_constraint(:code_hash)
  end
end
