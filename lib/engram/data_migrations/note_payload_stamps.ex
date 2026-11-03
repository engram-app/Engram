defmodule Engram.DataMigrations.NotePayloadStamps do
  @moduledoc """
  Every indexed note carries a `payload_hash`, which means its Qdrant points
  were verified (or rewritten) to hold its note-level payload. Each pass
  enqueues `ReconcileNotePayloads` per user who still has an unstamped note.

  The correctness case: a DEK rotation before rotations rewrote filter HMACs
  left every point of the user on the old filter key, so type/tag/folder/path
  filters matched nothing. Points are read and only drifted ones are written
  (`set_payload`, no re-embed), so for everyone else this costs reads and a
  row stamp per note.

  Not re-verified daily. Every writer since #2044 stamps the hash and a
  rotation rewrites and stamps it (`UserDekRotation`); a lost write race
  NULLs a stamp, and `Engram.Bookkeeping.Drain` finds those through the
  partial index `note_index_state_unstamped`.
  """
  @behaviour Engram.DataMigration

  alias Engram.Indexing.PayloadV6
  alias Engram.Workers.ReconcileNotePayloads

  @impl true
  def name, do: "note_payload_stamps"

  # Follows the payload shape: `PayloadV6.version/0` is 5 at the baseline, so
  # this is 1 today, and a shape bump is a new, not-done version whose pass
  # queues every note with an older `payload_version` (the drain only sees
  # NULL stamps). One source of truth for "points are behind".
  @impl true
  def version, do: PayloadV6.version() - PayloadV6.baseline() + 1

  @impl true
  def run_pass do
    case ReconcileNotePayloads.enqueue_missing() do
      0 -> :done
      users -> {:more, users: users}
    end
  end
end
