defmodule Engram.Repo.Migrations.AddNotesCountToUsageMeters do
  use Ecto.Migration

  @moduledoc """
  Pricing v2 §G — replace the per-insert `COUNT(*)` notes_cap check with a
  maintained counter on usage_meters. Backfills the live-note count (deleted_at
  IS NULL) for every user: updates existing meter rows and inserts rows for
  users who have notes but no meter yet.
  """

  def up do
    alter table(:usage_meters) do
      add :notes_count, :bigint, null: false, default: 0
    end

    flush()

    # Existing meter rows → set to current live-note count.
    execute """
    UPDATE usage_meters m
    SET notes_count = COALESCE(c.cnt, 0)
    FROM (
      SELECT user_id, COUNT(*) AS cnt
      FROM notes
      WHERE deleted_at IS NULL
      GROUP BY user_id
    ) c
    WHERE c.user_id = m.user_id
    """

    # Users with live notes but no meter row yet → create one. Other columns
    # rely on their DB defaults (updated_at default now(), counters default 0,
    # last_active_at stays NULL so we don't falsely mark them active).
    execute """
    INSERT INTO usage_meters (user_id, notes_count)
    SELECT n.user_id, COUNT(*)
    FROM notes n
    WHERE n.deleted_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM usage_meters m WHERE m.user_id = n.user_id)
    GROUP BY n.user_id
    """
  end

  def down do
    alter table(:usage_meters) do
      remove :notes_count
    end
  end
end
