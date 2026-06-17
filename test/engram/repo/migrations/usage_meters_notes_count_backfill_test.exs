defmodule Engram.Repo.Migrations.UsageMetersNotesCountBackfillTest do
  @moduledoc """
  Pins the notes_count backfill SQL embedded in the
  20260525001318_add_notes_count_to_usage_meters migration. The migration
  already ran in test DB setup; here we re-exercise the same SQL against
  synthetic users/notes inside a DataCase transaction (rolled back).
  """
  use Engram.DataCase, async: true

  alias Engram.Repo
  alias Engram.UsageMeters
  alias Engram.UsageMeters.Meter

  @update_sql """
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

  @insert_sql """
  INSERT INTO usage_meters (user_id, notes_count)
  SELECT n.user_id, COUNT(*)
  FROM notes n
  WHERE n.deleted_at IS NULL
    AND NOT EXISTS (SELECT 1 FROM usage_meters m WHERE m.user_id = n.user_id)
  GROUP BY n.user_id
  """

  defp run_backfill do
    Repo.query!(@update_sql)
    Repo.query!(@insert_sql)
  end

  test "updates an existing meter row to the live-note count (ignoring soft-deleted)" do
    user = insert(:user)
    Repo.insert!(%Meter{user_id: user.id, notes_count: 0})

    vault = insert(:vault, user: user)
    insert(:note, user: user, vault: vault)
    insert(:note, user: user, vault: vault)
    insert(:note, user: user, vault: vault, deleted_at: DateTime.utc_now())

    run_backfill()

    assert UsageMeters.notes_count(user.id) == 2
  end

  test "inserts a meter row for a user with notes but no existing meter" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    insert(:note, user: user, vault: vault)
    insert(:note, user: user, vault: vault)

    refute Repo.get(Meter, user.id)

    run_backfill()

    assert UsageMeters.notes_count(user.id) == 2
  end

  test "leaves a zero-note user's meter row at zero" do
    user = insert(:user)
    Repo.insert!(%Meter{user_id: user.id, notes_count: 0})

    run_backfill()

    assert UsageMeters.notes_count(user.id) == 0
  end

  test "is idempotent — a second run does not double-count" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    insert(:note, user: user, vault: vault)
    insert(:note, user: user, vault: vault)

    run_backfill()
    run_backfill()

    assert UsageMeters.notes_count(user.id) == 2
  end
end
