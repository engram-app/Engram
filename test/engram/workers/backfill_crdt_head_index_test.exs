defmodule Engram.Workers.BackfillCrdtHeadIndexTest do
  # The hourly `WarmCrdtHeads` discovery reads NULL heads through the partial
  # index on the narrow `note_bodies`, never a walk of `notes`.
  use Engram.DataCase, async: false

  alias Engram.Notes
  alias Engram.QueryPlan
  alias Engram.QueryRecorder
  alias Engram.Workers.BackfillCrdtHead

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Heads", Ecto.UUID.generate())
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "h.md", "content" => "h"}, actor: "api")
    %{user: user, vault: vault}
  end

  # Red before the change: discovery was an id-window walk of `notes`
  # (`SELECT id FROM notes WHERE id > ...`) with no `note_bodies` statement.
  test "discovery reads the NULL heads from note_bodies' partial index, not notes" do
    {count, queries} = QueryRecorder.record(fn -> BackfillCrdtHead.enqueue_all() end)
    assert count == 1

    candidate = Enum.find(queries, &(&1.sql =~ ~s(FROM "note_bodies")))
    assert candidate, "discovery no longer reads note_bodies"
    refute Enum.any?(queries, &(&1.sql =~ ~r/FROM "notes" AS \w+ WHERE .*"id" >/))

    plan = QueryPlan.generic_plan(candidate.sql, analyze: ["note_bodies"])
    assert plan =~ "note_bodies_crdt_head_null", plan
  end

  test "a note whose head is set is not a candidate", %{user: u} do
    Repo.query!("UPDATE notes SET crdt_head = $1", [
      Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    ])

    assert BackfillCrdtHead.enqueue_all() == 0
    _ = u
  end
end
