defmodule Engram.Repo.Migrations.IndexNotesCreatedRankExpand do
  use Ecto.Migration

  # `IndexCap.rank_below_cap?/2` orders a user's live notes by
  # `(created_at, id)` and takes `LIMIT cap`. Without a matching index that
  # LIMIT bounds only the OUTPUT: Postgres still reads every one of the user's
  # note rows and top-N sorts them, so each check is O(user's note count) and a
  # bulk import stays O(N^2) — the exact complexity the LIMIT was added to
  # remove. This index makes the scan itself stop after `cap` rows.
  #
  # Partial on the same predicate the query carries so it stays small: soft-
  # deleted rows and non-note kinds are never ranked.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Plain `create`, not `create_if_not_exists`: a CREATE INDEX CONCURRENTLY that
  # aborts (deploy timeout, lock conflict, dropped connection) leaves an INVALID
  # index behind. `IF NOT EXISTS` would then see the relation on the next deploy
  # and skip it, so the index stays invalid forever, the planner never uses it,
  # and the O(N^2) bulk import this migration exists to fix silently persists
  # behind a green migration log. Plain `create` fails loudly and forces a
  # DROP INDEX + re-run.
  def change do
    create index(
             :notes,
             [:user_id, :created_at, :id],
             name: :idx_notes_user_created_rank,
             where: "kind = 'note' AND deleted_at IS NULL",
             concurrently: true
           )
  end
end
