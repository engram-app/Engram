defmodule Engram.Notes.CrdtIndexPersistence do
  @moduledoc """
  Placeholder persistence for the per-vault index room (#1150).

  `Yex.Sync.SharedDoc` requires a `:persistence` module, and only `bind/3` is
  mandatory (`update_v1/4` and `unbind/3` are optional — see
  `deps/y_ex/lib/protocols/shared_doc.ex:350`). #1150 is deliberately inert:
  the room exists, syncs and can be observed, but nothing writes to it and
  nothing reads it back. So this binds an empty doc and stores nothing.

  **#1151 replaces this**, and until it does the index room is memory-only:
  when the room exits, its map is gone. That is why the room must NOT opt into
  the #1152 idle drain — draining a note room is lossless only because
  `CrdtPersistence.unbind/3` checkpoints it on the way out, and there is no
  equivalent here. See `Engram.Notes.CrdtIndexDoc`.
  """

  @behaviour Yex.Sync.SharedDoc.PersistenceBehaviour

  @impl true
  def bind(state, _doc_name, _doc), do: state
end
