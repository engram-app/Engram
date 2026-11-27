defmodule Engram.Notes.PreImageFence do
  @moduledoc """
  The one pre-image fence for every write of a note's CRDT state: the row
  must still be exactly the one the write read.

  Two halves, both required:

    * `seq`, the always-present half. Every committing content writer
      allocates a fresh one (`Vaults.next_seq!`), and a delete bumps it too.
    * the state's nonce. Every write of `crdt_state` encrypts it under a fresh
      one, so the nonce names the state version without shipping the TOASTed
      blob as a parameter. A compaction (including a genesis claim of a
      lineage-less row) sets state WITHOUT bumping seq, so seq alone is blind
      to it.

  A stateless pre-image is fenced with `IS NULL`, never `= NULL` (never true,
  which would fence a never-checkpointed row out of every write forever). The
  `IS NULL` is what makes a lineage claim atomic against every other writer:
  one that read the row before the claim committed matches zero rows and
  retries against the claimed state instead of replacing it.

  A row whose `notes.crdt_state_nonce` disagrees with its body row (drift,
  only from a restore or a hand edit) is fenced out in BOTH directions, since
  a loaded `%Note{}` takes its nonce from the body. `CrdtCheckpoint` reports
  such a miss rather than retrying it silently forever.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Notes.Note

  @doc "The fenced row: `note_id` at `pre`'s seq and state nonce."
  @spec query(Ecto.UUID.t(), %{seq: integer(), crdt_state_nonce: binary() | nil}) ::
          Ecto.Query.t()
  def query(note_id, %{seq: seq, crdt_state_nonce: nil}),
    do: from(n in Note, where: n.id == ^note_id and n.seq == ^seq and is_nil(n.crdt_state_nonce))

  def query(note_id, %{seq: seq, crdt_state_nonce: nonce}),
    do:
      from(n in Note,
        where: n.id == ^note_id and n.seq == ^seq and n.crdt_state_nonce == ^nonce
      )

  @doc """
  Lock the fenced row for the rest of the caller's transaction, or report
  that it moved. For writers that go through `Repo.update` (changeset
  validation and constraint mapping) and so cannot put a nil and a non-nil
  value in one filter map: take the lock here, then update by key.
  """
  @spec lock(Ecto.UUID.t(), %{seq: integer(), crdt_state_nonce: binary() | nil}, keyword()) ::
          :ok | :stale
  def lock(note_id, pre, repo_opts \\ []) do
    locked = from(n in query(note_id, pre), select: n.id, lock: "FOR UPDATE")

    case Engram.Repo.one(locked, repo_opts) do
      nil -> :stale
      _id -> :ok
    end
  end
end
