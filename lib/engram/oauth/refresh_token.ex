defmodule Engram.OAuth.RefreshToken do
  @moduledoc """
  Refresh token persisted as a sha256 hash. Carries `family_id` so that
  RFC 6749 §10.4 reuse-detection can revoke the whole family if an old
  token is replayed after rotation.

  Lifecycle:
    * fresh — `consumed_at` and `revoked_at` both nil, `expires_at` future
    * consumed — `consumed_at` set when used to mint a successor; replay
      after consumption triggers family-wide revocation
    * revoked — `revoked_at` set; can never mint anything
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "oauth_refresh_tokens" do
    field :token_hash, :string
    field :family_id, :binary_id
    field :client_id, :binary_id
    field :user_id, :integer
    field :vault_id, :integer
    field :scope, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :consumed_at, :utc_datetime

    # Read-only tracking fields populated at token-rotation time.
    # last_used_ip is :string for the same reason as Client.first_ip — the DB
    # column is inet but Postgrex.INET is not an Ecto primitive.
    field :last_used_at, :utc_datetime_usec
    field :last_used_ip, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @cast ~w(token_hash family_id client_id user_id vault_id scope expires_at)a
  @required ~w(token_hash family_id client_id user_id expires_at)a

  def changeset(token, attrs) do
    token
    |> cast(attrs, @cast)
    |> validate_required(@required)
    |> unique_constraint(:token_hash)
  end
end
