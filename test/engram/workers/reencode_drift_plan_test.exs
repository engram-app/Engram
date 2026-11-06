defmodule Engram.Workers.ReencodeDriftPlanTest do
  @moduledoc """
  `ReencodeEnvelopes.enqueue_missing/0` counts each user's drifted legacy note
  bodies on every pass. A COUNT never stops early, so it must start from the
  `note_bodies_envelope_legacy` partial index (empty in steady state), not
  walk the user's notes (`docs/context/maintenance-job-db-load.md`, rule 3).
  """
  use Engram.DataCase, async: false

  alias Engram.QueryPlan
  alias Engram.Workers.ReencodeEnvelopes

  @notes 60

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    for i <- 1..@notes, do: Engram.Fixtures.insert_note!(user, vault, %{path: "n#{i}.md"})
    %{user: user}
  end

  for label <- [:notes_content, :notes_crdt_state] do
    test "the #{label} drift count reads the envelope_legacy partial index", %{user: user} do
      {sql, _params} =
        Repo.to_sql(:all, ReencodeEnvelopes.drifted_query(unquote(label), user.id))

      plan = QueryPlan.generic_plan(sql, analyze: ~w(notes note_bodies), fresh: true)
      assert plan =~ "note_bodies_envelope_legacy", "plan:\n#{plan}\n\nsql:\n#{sql}"
    end
  end
end
