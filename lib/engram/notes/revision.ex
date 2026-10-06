# lib/engram/notes/revision.ex
defmodule Engram.Notes.Revision do
  @moduledoc """
  One version of a note: an editing session by one actor (#1710, epic #609).

  A row is OPEN while `closed_at` is nil. The open version has no copy of its
  text anywhere, because its text IS the note. When a later save starts a new
  version, `Engram.Notes.Revisions.record_write/4` closes this row and copies
  the note's old content ciphertext into `pending_*`, in the same transaction
  as that save. `Engram.Workers.FinalizeRevision` then moves the copy into
  `Engram.Storage` and clears `pending_*`.
  """
  use Engram.Schema
  import Ecto.Changeset

  @origins ~w(edit baseline restore)

  @type t :: %__MODULE__{}

  schema "note_revisions" do
    field :note_id, Ecto.UUID
    field :user_id, Ecto.UUID
    field :vault_id, Ecto.UUID
    field :actor, :string
    field :origin, :string
    field :actor_user_id, Ecto.UUID
    field :restored_from_id, Ecto.UUID
    field :session_started_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :pending_ciphertext, :binary, redact: true
    field :pending_nonce, :binary, redact: true
    field :pending_dek_version, :integer
    field :finalize_failed_at, :utc_datetime_usec
    field :storage_key, :string
    field :blob_nonce, :binary
    field :content_hash, :string
    field :char_count, :integer
    field :dek_version, :integer, default: 2

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(note_id user_id vault_id actor origin session_started_at)a
  @copy ~w(closed_at pending_ciphertext pending_nonce pending_dek_version)a

  @doc "A new open version."
  def open_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_inclusion(:origin, @origins)
    |> unique_constraint(:note_id, name: :note_revisions_one_open_per_note)
  end

  @doc "A version born closed, carrying an outbox copy. Used for the baseline."
  def closed_copy_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required ++ @copy ++ [:content_hash])
    |> validate_required(@required ++ @copy)
    |> validate_inclusion(:origin, @origins)
  end
end
