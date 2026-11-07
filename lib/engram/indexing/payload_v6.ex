defmodule Engram.Indexing.PayloadV6 do
  @moduledoc """
  The payload version a release writes, and its per-note stamp
  (`note_index_state.payload_version`). The parked folder-row-id payload this
  module once built is retired, and so is every payload builder: since R3a a
  point's payload is its identity (`Engram.Indexing.identity_payload/1`).
  See `docs/context/payload-v6.md`.
  """

  import Ecto.Query, only: [from: 2, where: 2]

  alias Engram.Notes.Note
  alias Engram.Notes.NoteIndexState
  alias Engram.Repo
  alias Engram.ServiceConfig

  # The payload shape a release writes. Bumping it makes
  # `Engram.Workers.ReconcileNotePayloads` bring every note's points to the new
  # shape, with no embedder call and no operator step. A note whose stamp
  # (`note_index_state.payload_version`) is NULL was written before the stamp
  # existed, which is `@baseline`; stamps are compared with `<`, so a newer
  # stamp is current and a rollback rebuilds nothing.
  #
  # 6: every v5 point carries `n`, its note row id (immutable chunk index,
  # Engram#2263).
  @baseline 5
  @version 6

  @doc "The payload version this release writes (test builds: `:payload_version` override)."
  @spec version() :: pos_integer()
  def version, do: ServiceConfig.get(:payload_version, @version)

  @doc """
  Stamps `note_id`'s points as written with `version/0`
  (`note_index_state.payload_version`), never lowering a newer stamp. With
  `hash:`, only while the note row holds that `payload_hash` (an index pass
  whose compare-and-set stamp missed must not vouch for the version either).
  Runs in the caller's tenant transaction.
  """
  @spec stamp(Ecto.UUID.t(), keyword()) :: :ok
  def stamp(note_id, opts \\ []) do
    version = version()

    query =
      from(s in NoteIndexState,
        where: s.note_id == ^note_id,
        where: is_nil(s.payload_version) or s.payload_version < ^version
      )

    query =
      case Keyword.fetch(opts, :hash) do
        {:ok, hash} ->
          held =
            from(n in Note,
              where: n.kind == "note" and n.id == ^note_id and n.payload_hash == ^hash,
              select: 1
            )

          where(query, exists(held))

        :error ->
          query
      end

    {_, _} = Repo.update_all(query, set: [payload_version: version])
    :ok
  end

  @doc "The version of a note whose stamp is NULL: the shape before the stamp existed."
  @spec baseline() :: 5
  def baseline, do: @baseline
end
