defmodule Engram.Notes.FolderHash do
  @moduledoc """
  R9 release E: whether a note write sets `notes.folder_hmac`.

  A note's folder is its `folder_ref_id`; the hash stays only while something
  can still read it. Release E's prerequisites take every reader away: the
  rollback floor at C (0.76 matches folder search and rename targets by the
  hash, 0.78.1 its folder delete), the fleet on D or later, and R3a in prod
  (it removed every chunk `f` reader). What is left is a runtime gate,
  `Engram.DataMigrations.NotePayloadStamps.done?/0` (every Qdrant point has
  `n`): open, every write sets the hash as before; done, a path change of a
  non-root note writes NULL, never a stale hash. A reopened ledger turns the
  hash back on, on every node (`Engram.DataMigrations.reopen/2` broadcasts).
  Zero operator action; a self-host install stops at its own pace.

  A root note keeps its hash (the HMAC of `""`): the root is never renamed,
  so it cannot go stale. Markers are not notes: they keep theirs (their path
  identity).

  Cost per write: `write?/0` is one `:persistent_term` read once the ledger
  is done; before that, one ETS read (the `false` answer is cached for 60 s
  per node), so at most one `data_migrations` query per node a minute. Every
  note write asks, the root included, so any write keeps the cache warm.
  """

  alias Engram.Cache
  alias Engram.Crypto
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NotePayloadStamps

  @doc "Whether note writes set `folder_hmac` on this node now (the ledger is not done)."
  @spec write?() :: boolean()
  def write?, do: not stamps_done?()

  @doc """
  The `folder_hmac` a note write sets for `folder`: the hash while `write?/0`,
  NULL after, except for the root (`""`), which always keeps it.
  """
  @spec for_note(binary(), String.t()) :: binary() | nil
  def for_note(filter_key, folder) do
    if write?() or folder == "", do: Crypto.hmac_field(filter_key, folder)
  end

  # `done?/0` caches only `true` (`:persistent_term`, erased cluster-wide by
  # a reopen). The `false` answer is cached here for the TTL, so a write does
  # not query the ledger: a stale `false` keeps writing the hash, the safe
  # direction.
  defp stamps_done? do
    DataMigrations.cached_done?(NotePayloadStamps.name(), NotePayloadStamps.version()) or
      Cache.fetch(:folder_hash_gate, :stamps_done, &load/0)
  end

  defp load, do: if(NotePayloadStamps.done?(), do: Cache.no_store(true), else: false)
end
