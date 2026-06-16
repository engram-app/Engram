defmodule Engram.Onboarding.MigrationTest do
  use Engram.DataCase, async: true

  alias Engram.Repo

  # PG18+UUIDv7 rework: id + user_id are uuid (matches users.id).
  test "onboarding_actions table exists with expected columns + unique index" do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_name = 'onboarding_actions'
        ORDER BY column_name
        """,
        []
      )

    cols = Map.new(rows, fn [name, type, nullable] -> {name, {type, nullable}} end)

    assert {"uuid", "NO"} = cols["id"]
    assert {"uuid", "NO"} = cols["user_id"]
    assert {_text, "NO"} = cols["action"]
    assert {"jsonb", _} = cols["metadata"]
    assert {"timestamp with time zone", "NO"} = cols["inserted_at"]

    %{rows: [[true]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE tablename = 'onboarding_actions'
            AND indexdef LIKE '%UNIQUE%user_id%action%'
        )
        """,
        []
      )

    %{rows: [[rls, force_rls]]} =
      Repo.query!(
        "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'onboarding_actions'",
        []
      )

    assert rls == true
    assert force_rls == true
  end
end
