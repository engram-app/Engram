defmodule Engram.Notes.VaultIndexState do
  @moduledoc """
  The encrypted `filemeta_v0` snapshot for one vault's index room (#1151).

  One row per vault, upserted when the room exits and read when it binds.
  Snapshot-only: there is no per-update tail log the way `notes.crdt_state` has
  `crdt_update_log`. Index writes are rename/create/delete rather than
  keystrokes, and until Engram-obsidian#363 the `notes` rows stay authoritative
  for paths — so losing a checkpoint interval leaves the index STALE, never
  silently wrong. No rebuild path exists in `lib/`; what makes staleness
  tolerable today is that nothing reads the index. Add a tail log when that
  stops being true.

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
