defmodule Engram.Notes.VaultIndexState do
  @moduledoc """
  The encrypted `filemeta_v0` snapshot for one vault's index room (#1151).

  One row per vault, upserted when the room exits and read when it binds.

  This is the SNAPSHOT half of a two-part record. `vault_index_update_log` is
  the other: every update is appended there as it happens, and a checkpoint
  folds the tail into this row and prunes exactly what it folded (#1391). So a
  bind reads this row and then replays whatever tail survived it.

  The tail exists because the map is authoritative for paths
  (`docs/context/crdt-identity-authority.md`). Losing a checkpoint interval used
  to leave the index merely STALE, with the `notes` rows still holding the
  truth; under map-authority it loses committed path CLAIMS outright, and
  projection then drags the rows back to the superseded snapshot.

  Keyed by `vault_id` rather than a surrogate `id`, which is why the AAD is
  built explicitly (`Crypto.encrypt_index_state/3`) instead of going through
  `Crypto.decrypt_aad/3` — that helper binds to `row.id`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:vault_id, :binary_id, autogenerate: false}
  schema "vault_index_states" do
    field :user_id, :binary_id
    field :state_ciphertext, :binary
    field :state_nonce, :binary
    field :dek_version, :integer, default: 2

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:vault_id, :user_id, :state_ciphertext, :state_nonce, :dek_version]

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, @fields)
    |> validate_required(@fields)
  end
end
