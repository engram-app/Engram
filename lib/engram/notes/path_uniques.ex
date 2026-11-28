defmodule Engram.Notes.PathUniques do
  @moduledoc """
  The unique indexes on `notes` whose violation means "the target is taken":
  the path and folder-marker indexes, legacy and current (20260605000353,
  20261021110300), and release L's name collision guard `notes_name_live`
  (`Engram.Release.NotesPathExpand`). Any other 23505 is a bug and is
  re-raised. `Engram.Notes.Note.changeset/2` maps the same names to the same
  changeset error, so a refusal by `notes_name_live` reaches every client
  exactly as a path index refusal does.

  `conflict/2` is the race backstop every multi-row write goes through: a row
  that lands after a caller's pre-checks (or a row the pre-checks cannot see,
  such as a stale name key the by-name lookup does not trust) still trips the
  index, and that is the same refusal as a pre-checked `:conflict`, so every
  caller answers it (REST 409, MCP `path_conflict`, the wire's `conflict`)
  instead of a 500 or a crashed crdt channel (e2e run 44283703701). Call it
  OUTSIDE the transaction: the raise already rolled it back whole; inside
  it, the next statement would fail with 25P02
  (docs/context/rls-enforcement-testing-traps.md, trap 8).
  """

  alias Engram.Logger.Metadata

  require Logger

  @names ~w(notes_user_vault_folder_marker notes_user_vault_path_v2
            notes_folder_marker notes_path_live notes_name_live)

  @doc "The index names (read by the schema test that keeps them to real indexes)."
  def names, do: @names

  @doc """
  Runs `fun`; a unique violation on one of `names/0` is `{:error, :conflict}`
  and a warning naming `op` and the index. Anything else propagates.
  """
  @spec conflict((-> result), String.t()) :: result | {:error, :conflict} when result: term()
  def conflict(fun, op) do
    fun.()
  rescue
    e in Postgrex.Error ->
      constraint = e.postgres[:constraint]

      if e.postgres[:code] == :unique_violation and constraint in @names do
        Logger.warning(
          "#{op}: path taken at write, answered conflict",
          Metadata.with_category(:warning, :sync, constraint: constraint)
        )

        {:error, :conflict}
      else
        reraise e, __STACKTRACE__
      end
  end
end
