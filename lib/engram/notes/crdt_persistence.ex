defmodule Engram.Notes.CrdtPersistence do
  @moduledoc """
  Memory-only persistence stub for `Engram.Notes.CrdtDoc`.

  Implements only `bind/3` returning `:ok` so the room starts without hitting
  Postgres. Task 7 replaces this with the real encrypted-blob persistence.
  `unbind/3` and `update_v1/4` are intentionally omitted — they are optional
  callbacks in `Yex.Sync.SharedDoc.PersistenceBehaviour`.
  """

  @behaviour Yex.Sync.SharedDoc.PersistenceBehaviour

  @impl true
  def bind(_state, _doc_name, _doc), do: :ok
end
