defmodule Engram.Repo.Migrations.IndexNoteIndexStateVaultExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # The vault's chunk totals are a SUM over its notes' counters
  # (`note_index_state.points` / `len_rows` / `len_sum`): BM25 avgdl and the
  # point count read them by vault. Key only, no INCLUDE: a recount then
  # changes no indexed column and stays HOT.
  def up do
    # A CONCURRENTLY build that fails leaves an INVALID index under its name;
    # dropping the name first makes the retry rebuild it.
    drop_if_exists index(:note_index_state, [:vault_id],
                     name: :note_index_state_vault,
                     concurrently: true
                   )

    create index(:note_index_state, [:vault_id],
             name: :note_index_state_vault,
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:note_index_state, [:vault_id],
                     name: :note_index_state_vault,
                     concurrently: true
                   )
  end
end
