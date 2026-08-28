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

  def change do
    create_if_not_exists index(
                           :notes,
                           [:user_id, :created_at, :id],
                           name: :idx_notes_user_created_rank,
                           where: "kind = 'note' AND deleted_at IS NULL",
                           concurrently: true
                         )
  end
end
