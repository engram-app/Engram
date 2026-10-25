defmodule Engram.Notes.NoteIndexState do
  @moduledoc """
  A note's embed bookkeeping, 1:1 with `notes` (migration 20261025000000):
  hashes, version stamps, the crash guard, the Free bucket queue and the v5
  tier. Same column names as `notes`. Written only by the
  `notes_sync_index_state` trigger (and the `NoteIndexState` backfill);
  nothing reads it until readers switch (the next release), then `notes`
  stops carrying these columns (contract).
  """
  use Ecto.Schema

  @primary_key {:note_id, :binary_id, autogenerate: false}
  schema "note_index_state" do
    field :user_id, :binary_id
    field :embed_retry_after, :utc_datetime_usec
    field :embed_started_at, :utc_datetime_usec
    field :rebuild_paid_at, :utc_datetime_usec
    field :embed_budget_parked_at, :utc_datetime_usec
    field :embed_budget_need, :integer
    field :embed_budget_next, :integer
    field :chunk_count, :integer
    field :chunker_version, :integer
    field :keyword_version, :integer
    field :key_alias_version, :integer
    field :embed_crashes, :integer
    field :embed_budget_parked, :boolean
    field :index_tier, :string
    field :embed_model, :string
    field :embed_started_by, :string
    field :embed_hash, :string
    field :dense_indexed_hash, :string
    field :embed_started_hash, :string
    field :payload_hash, :binary
  end

  @doc "The mirrored columns, for comparing a state row to its note."
  def mirrored,
    do: __schema__(:fields) -- [:note_id, :user_id]
end
