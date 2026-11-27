defmodule Engram.Workers.ReconcileKeywordPagePlanTest do
  # The reconcile walk's page read (review L4), planned as prod runs it: as
  # `engram_app` under FORCE RLS, custom and generic (`QueryPlan.rls_plans/3`).
  # One page of a user's notes must stop at its LIMIT; it never aggregates
  # every note and chunk of the user first (a GROUP BY under the LIMIT made a
  # large user's walk O(notes^2 / page)).
  use Engram.DataCase, async: false

  alias Engram.QueryPlan
  alias Engram.Repo
  alias Engram.Workers.ReconcileKeywordIndex

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    for _ <- 1..300, do: insert(:note, user: user, vault: vault)
    QueryPlan.fresh!("notes")
    %{user: user}
  end

  test "a page reads its notes in id order and stops at the limit", %{user: user} do
    {sql, params} =
      Repo.to_sql(:all, ReconcileKeywordIndex.page_query(user.id, Ecto.UUID.generate(), 20))

    %{custom: custom, generic: generic} = QueryPlan.rls_plans(user.id, sql, params)

    for plan <- [custom, generic] do
      assert plan =~ ~r/\ALimit/, "the page is not a streaming LIMIT\n" <> plan

      refute plan =~ ~r/HashAggregate|GroupAggregate|Sort/,
             "the page aggregates or sorts\n" <> plan
    end
  end
end
