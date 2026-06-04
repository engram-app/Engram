defmodule Engram.Onboarding.MigrationTest do
  use Engram.DataCase, async: false

  alias Engram.Repo

  # NOTE: spec literal asserted uuid for id/user_id, but `users.id` is bigint
  # in this repo, so every per-user table mirrors that. Asserting bigint here
  # matches the actual migration; the rest of the schema contract (action text
  # not-null, metadata jsonb, inserted_at timestamptz not-null) + unique index
  # is unchanged from the spec.
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

    assert {"bigint", "NO"} = cols["id"]
    assert {"bigint", "NO"} = cols["user_id"]
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
