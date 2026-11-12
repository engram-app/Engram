defmodule Engram.Folders.WalkSql do
  @moduledoc """
  The SQL text of the folder reads that run inside another statement, one
  copy each (O(1) folder rename plan, S3, Engram#2523). Ecto's `fragment/1`
  takes only a compile-time string, so each is a macro that expands to one:
  `require` this module, then `fragment(WalkSql.key_eq(), ...)`.

    * The walk: the live folder at the end of a path's segments (their
      `name_hmac`s, root first, as a `bytea[]`), one probe of
      `folders_live_name` per level (unique, so at most one row a level and
      the scalar subquery never sees two; none gives NULL, which matches
      nothing). Each level is a LATERAL probe keyed by the level above, so
      the planner cannot hash-join a whole vault's folders per level.
      Uncorrelated, so it runs once (an InitPlan). Params: vault id, segment
      hashes, vault id, segment hashes, depth. It reads `folders` in the
      statement's own tenant (FORCE RLS).
    * `moved/0`: whether a vault has a live folder renamed without a cascade
      (`notes_cascaded = false`, written from S5 on), on
      `folders_moved_live`. Param: vault id.
  """

  @walk """
  (WITH RECURSIVE w(i, id) AS (
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
   ) SELECT w.id FROM w WHERE w.i = ?)
  """

  @doc "`? = <walk>`: a folder id column against the walk (params: column, then the walk's)."
  defmacro id_eq, do: "? = " <> @walk

  @doc """
  `(? || uuid_send(?)) = (? || uuid_send(<walk>))`: a note's
  `(name_ci_hmac, folder_ref_id)` key, as `notes_folder_name_live` indexes
  it, against a casefolded name hash plus the walk (params: the two
  columns, the name hash, then the walk's).
  """
  defmacro key_eq, do: "(? || uuid_send(?)) = (? || uuid_send(" <> @walk <> "))"

  @doc "`EXISTS` a live folder of the vault renamed without a cascade (param: vault id)."
  defmacro moved,
    do:
      "EXISTS (SELECT 1 FROM folders m WHERE m.vault_id = ? AND NOT m.notes_cascaded " <>
        "AND m.deleted_at IS NULL)"
end
