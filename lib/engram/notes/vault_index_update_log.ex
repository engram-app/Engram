defmodule Engram.Notes.VaultIndexUpdateLog do
  @moduledoc """
  Append-only encrypted Yjs update row for a vault's `filemeta_v0` index room.

  The tail that makes the index durable BETWEEN checkpoints (#1391), mirroring
  `Engram.Notes.CrdtUpdateLog` for note rooms. Compacted on checkpoint.

  `vault_index_states` alone was snapshot-only, written when a room exits. That
  was sound while the `notes` rows were authoritative for paths — a lost
  interval left the index STALE and the rows still held the truth. #1151 step 2
  made the MAP authoritative (`docs/context/crdt-identity-authority.md`), so a
  lost interval now drops committed path CLAIMS and the rows converge back to a
  superseded snapshot on the next projection run.

  Keyed by its own id rather than the vault, because rows are appended and then
  pruned by EXACT id — see `CrdtIndexPersistence`'s checkpoint, which must not
  prune a row it did not fold in.
  """
  use Engram.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "vault_index_update_log" do
    field :vault_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :update_ciphertext, :binary
    field :update_nonce, :binary
    field :dek_version, :integer, default: 2
    field :inserted_at, :utc_datetime_usec
  end

  @fields [:id, :vault_id, :user_id, :update_ciphertext, :update_nonce, :dek_version]
  @required [:vault_id, :user_id, :update_ciphertext, :update_nonce]

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, @fields)
    |> validate_required(@required)
  end
end
