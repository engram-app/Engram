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

  Not re-verified: every writer since #2044 stamps the hash, and a rotation
  now rewrites and stamps it (`UserDekRotation`).
  """
  @behaviour Engram.DataMigration

  alias Engram.Workers.ReconcileNotePayloads

  @impl true
  def name, do: "note_payload_stamps"

  @impl true
  def version, do: 1

  @impl true
  def run_pass do
    case ReconcileNotePayloads.enqueue_missing() do
      0 -> :done
      users -> {:more, users: users}
    end
  end
end
