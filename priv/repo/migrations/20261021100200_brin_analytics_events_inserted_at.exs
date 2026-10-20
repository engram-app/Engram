defmodule Engram.Repo.Migrations.BrinAnalyticsEventsInsertedAt do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # analytics_events is append-only and buffered rows land in time order
  # (Analytics.EventLog flushes every 5 s), so inserted_at follows the heap.
  # Its readers are time ranges: the hourly retention sweep (`< cutoff`), the
  # daily snapshot's rollups and the operator insights (`>= start`). A BRIN
  # summary per 128-block range serves those for a few pages total, where the
  # btree carried about 31 bytes per event, and the table grows per event for
  # two years. Lookups by user or event keep their (x, inserted_at) btrees.
  # AnalyticsEventsBrinPlanTest pins the sweep's plan.
  def up do
    create_if_not_exists index(:analytics_events, [:inserted_at],
                           name: :analytics_events_inserted_at_brin,
                           using: :brin,
                           concurrently: true
                         )

    drop_if_exists index(:analytics_events, [:inserted_at], concurrently: true)
  end

  def down do
    create_if_not_exists index(:analytics_events, [:inserted_at], concurrently: true)

    drop_if_exists index(:analytics_events, [:inserted_at],
                     name: :analytics_events_inserted_at_brin,
                     concurrently: true
                   )
  end
end
