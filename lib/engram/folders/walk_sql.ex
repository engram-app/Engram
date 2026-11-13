defmodule Engram.Folders.WalkSql do
  @moduledoc """
  The SQL text of the folder reads that run inside another statement, one
  copy each (O(1) folder rename plan, S3, Engram#2523). Ecto's `fragment/1`
  takes only a compile-time string, so each is a macro that expands to one:
  `require` this module, then `fragment(WalkSql.id_eq(), ...)`.

    * The walk: the live folder at the end of a path's segments (their
      `name_hmac`s, root first, as a `bytea[]`), one probe of
      `folders_live_name` per level (unique, so at most one row a level and
      the scalar subquery never sees two; none gives NULL, which matches
      nothing). Each level is a LATERAL probe keyed by the level above, so
      the planner cannot hash-join a whole vault's folders per level.
      Uncorrelated, so it runs once (an InitPlan). Params: vault id, segment
      hashes, vault id, segment hashes, then the depth. It reads `folders`
      in the statement's own tenant (FORCE RLS).
    * `moved/0`: whether a vault has a live folder renamed without a cascade
      (`notes_cascaded = false`, written from S5 on), on
      `folders_moved_live`. Param: vault id.

  Under FORCE RLS a qual can drive an index only if every function it
  applies to a column is leakproof (docs/context/rls-leakproof-index-quals.md).
  So no predicate here applies one to a column: each compares a plain
  column to a bound value, a walk result or a subquery's (an InitPlan
  parameter).
  """

  @walk """
  WITH RECURSIVE w(i, id) AS (
     SELECT 1, f.id FROM folders f
     WHERE f.vault_id = ? AND f.parent_id IS NULL AND f.name_hmac = (?)[1]
       AND f.deleted_at IS NULL
     UNION ALL
     SELECT w.i + 1, c.id FROM w CROSS JOIN LATERAL (
       SELECT f.id FROM folders f
       WHERE f.vault_id = ? AND f.parent_id = w.id AND f.name_hmac = (?)[w.i + 1]
         AND f.deleted_at IS NULL
       LIMIT 1
     ) c
   )
  """

  @moved "EXISTS (SELECT 1 FROM folders m WHERE m.vault_id = ? AND NOT m.notes_cascaded " <>
           "AND m.deleted_at IS NULL)"

  # The note a path's folder row and name name: `notes.name_key` (the
  # casefolded name hash plus the folder row's id, kept by the
  # `notes_set_name_key` trigger, NULL unless the name keys are current)
  # against the walk's folder with the asked name's hash, on
  # `notes_name_key_live`, the exact name, and no live note holding the
  # path (`holder`). The lowest id of the matches, so one row, never two.
  # Only when the vault holds a folder moved without a cascade: otherwise
  # NULL, and neither the walk nor the probe runs.
  #
  # Params: vault id (moved), vault id, the walk's four, the casefolded
  # name hash, the depth, the exact name hash, then the holder's.
  name_match = fn holder ->
    "(CASE WHEN " <>
      @moved <>
      " THEN (SELECT m.id FROM notes m WHERE m.vault_id = ? AND m.name_key = (" <>
      @walk <>
      " SELECT ? || uuid_send(w.id) FROM w WHERE w.i = ?) AND m.name_hmac = ? " <>
      "AND m.deleted_at IS NULL AND m.kind = 'note' AND NOT EXISTS (" <>
      holder <> ") ORDER BY m.id LIMIT 1) END)"
  end

  @by_id name_match.(
           "SELECT 1 FROM notes p WHERE p.vault_id = ? AND p.path_id = ? " <>
             "AND p.deleted_at IS NULL AND NOT p.is_folder"
         )

  @by_hmac name_match.(
             "SELECT 1 FROM notes p WHERE p.vault_id = ? AND p.path_hmac = ? " <>
               "AND p.deleted_at IS NULL AND p.kind = 'note'"
           )

  @doc "`? = (<walk>)`: a folder id column against the walk (params: column, then the walk's, then the depth)."
  defmacro id_eq, do: "? = (" <> @walk <> " SELECT w.id FROM w WHERE w.i = ?)"

  @doc """
  The id of the note the path's folder row and name name, or NULL
  (the name match above): the holder keyed on `path_id` (`note_split` done).
  Params: vault id x2, the walk's four, casefolded name hash, depth, exact
  name hash, vault id, path id.
  """
  defmacro name_match_by_id, do: @by_id

  @doc "`name_match_by_id/0` with the holder keyed on `path_hmac` (before `note_split`)."
  defmacro name_match_by_hmac, do: @by_hmac

  @doc "`EXISTS` a live folder of the vault renamed without a cascade (param: vault id)."
  defmacro moved, do: @moved
end
