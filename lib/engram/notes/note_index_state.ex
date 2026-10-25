defmodule Engram.Notes.NoteIndexState do
  @moduledoc """
  A note's embed bookkeeping, 1:1 with `notes` (migration 20261025000000):
  hashes, version stamps, the crash guard, the Free bucket queue and the v5
  tier, same column names as `notes`, written only by the
  `notes_sync_index_state` trigger (and the `NoteIndexState` backfill);
  nothing reads them until readers switch (the next release). Plus the
  note's chunk counters, written by the chunk writers and read as vault
  sums for BM25 avgdl and the point count.
  """
  use Ecto.Schema

  @primary_key {:note_id, :binary_id, autogenerate: false}
  schema "note_index_state" do
    field :user_id, :binary_id
    field :vault_id, :binary_id
    # The note's chunk counters (`Indexing.ChunkRows.recount!/1`), not
    # mirrored from `notes`.
    field :points, :integer, default: 0
    field :len_rows, :integer, default: 0
    field :len_sum, :integer, default: 0
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
    do: __schema__(:fields) -- [:note_id, :user_id, :points, :len_rows, :len_sum]
end
