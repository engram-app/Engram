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
    * superseded — `revoked_at` and `superseded_at` set by a grace re-issue;
      can never mint, but leaves its family live
  """
  use Engram.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "oauth_refresh_tokens" do
    field :token_hash, :string
    field :family_id, :binary_id
    field :client_id, :binary_id
    field :user_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    # Multi-vault grants. NULL = all vaults (including ones created later).
    # A non-empty list = exactly that set. `vault_id` above is dual-written
    # with the FIRST id of that set (see Engram.OAuth.scalar_vault_id/1) so a
    # rolled-back reader narrows to one vault rather than widening to all,
    # until a later release drops it.
    field :vault_ids, {:array, Ecto.UUID}
    # Per-vault levels (#174): `%{vault_id => "none" | "read" | "write"}` and
    # the level for every vault not listed. Both NULL = a pre-levels grant.
    # Read through `Engram.OAuth.access_claims/1`, never directly.
    field :vault_access, :map
    field :default_access, :string
    # User-typed name for this grant, copied from the authorization code at
    # exchange and carried across every rotation. NULL falls back to the OAuth
    # client's own identity in the connections list.
    field :label, :string
    field :scope, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :consumed_at, :utc_datetime
    # Set with `revoked_at` when a grace re-issue replaced this unused
    # successor (#1974). Such a row never mints, but does not revoke its
    # family (`Engram.OAuth.family_unrevoked/1`). Written by update only.
    field :superseded_at, :utc_datetime
    # The row this one was minted from by rotation or grace re-issue. NULL on
    # a family's first row and on rows from before the column.
    field :parent_id, :binary_id

    # Read-only tracking fields populated at token-rotation time.
    field :last_used_at, :utc_datetime_usec
    # Task 7 NOTE: :inet at the DB level may return %Postgrex.INET{} struct
    # when loaded; verify round-trip before adding to @cast_fields, may need
    # a custom Ecto type.
    field :last_used_ip, :string, redact: true

    # The redirect the grant ACTUALLY used, copied from the authorization code
    # at exchange and carried across every rotation. Not the client's
    # registered list: a client may register several redirects, and the badge
    # in `Engram.Connections.LogoAllowlist` must reflect where the code was
    # delivered, not where it could have been. NULL on grants predating the
    # column, which resolve as unverified. See #1204.
    field :redirect_uri, :string

    # When the grant (this family) was created: set at code exchange and
    # copied unchanged onto every rotation successor. NULL on rows minted
    # before the column; `Engram.OAuth.granted_at/1` then falls back to the
    # family's earliest `inserted_at`, and the next rotation stores it.
    field :granted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @cast ~w(token_hash family_id client_id user_id vault_id vault_ids vault_access default_access label
           scope expires_at last_used_at last_used_ip redirect_uri granted_at parent_id)a
  @required ~w(token_hash family_id client_id user_id expires_at)a

  def changeset(token, attrs) do
    token
    |> cast(attrs, @cast)
    |> validate_required(@required)
    |> unique_constraint(:token_hash)
  end
end
