defmodule Engram.Repo.Migrations.UserVaultExtendedStatistics do
  use Ecto.Migration

  # vault_id determines user_id, and every scoped query states both, so the
  # planner multiplied two selectivities and expected a fraction of a vault's
  # rows (2 for a 20-note vault in ExtendedStatisticsTest). Functional
  # dependency + ndistinct statistics on (user_id, vault_id) fix the estimate.
  # Catalog-only (SHARE UPDATE EXCLUSIVE: reads and writes carry on); the
  # next ANALYZE, autovacuum's included, fills them, with no operator step.
  @tables ~w(notes attachments note_links chunks)

  def up do
    for t <- @tables do
      execute "CREATE STATISTICS IF NOT EXISTS #{t}_user_vault_stats (dependencies, ndistinct) " <>
                "ON user_id, vault_id FROM #{t}"
    end
  end

  def down do
    for t <- @tables, do: execute("DROP STATISTICS IF EXISTS #{t}_user_vault_stats")
  end
end
