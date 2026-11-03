defmodule Engram.Workers.BackfillCrdtHeadIndexTest do
  # The hourly `WarmCrdtHeads` discovery reads a bounded primary-key window of
  # `note_bodies` plus the notes written since the last run, never a walk of
  # `notes` and never an index on the head (HOT, NoteBodyReadTest).
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
  test "discovery reads a key window of note_bodies, not a walk of notes", %{
    user: u,
    vault: v
  } do
    # Realistic statistics: most bodies carry a head, so a primary-key walk
    # filtering on `crdt_head IS NULL` costs more than the partial index.
    for i <- 1..150 do
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "w#{i}.md", "content" => "w"}, actor: "api")
    end

    head = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    Repo.query!("UPDATE notes SET crdt_head = $1 WHERE path_ciphertext IS NOT NULL", [head])

    Repo.query!(
      "UPDATE notes SET crdt_head = NULL WHERE id = (SELECT id FROM notes ORDER BY id LIMIT 1)"
    )

    {count, queries} = QueryRecorder.record(fn -> BackfillCrdtHead.enqueue_all() end)
    assert count == 1

    candidate = Enum.find(queries, &(&1.sql =~ ~s(FROM "note_bodies")))
    assert candidate, "discovery no longer reads note_bodies"
    refute Enum.any?(queries, &(&1.sql =~ ~r/FROM "notes" AS \w+ WHERE .*"id" >/))

    plan = QueryPlan.generic_plan(candidate.sql, analyze: ["note_bodies"])
    assert plan =~ "note_bodies_pkey", plan
    assert plan =~ "Limit", plan
  end

  test "a note whose head is set is not a candidate", %{user: u} do
    Repo.query!("UPDATE notes SET crdt_head = $1", [
      Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    ])

    assert BackfillCrdtHead.enqueue_all() == 0
    _ = u
  end

  # Red on c0c603cb9: the first `cap` rows of the index were read every run, so
  # NULL-head rows that never warm (trashed notes) ahead of a live one filled
  # every run and the live note never warmed.
  test "rows that never warm cannot starve a live note behind them", %{user: u, vault: v} do
    Application.put_env(:engram, :crdt_head_candidate_cap, 2)
    on_exit(fn -> Application.delete_env(:engram, :crdt_head_candidate_cap) end)

    Repo.query!("UPDATE notes SET deleted_at = now()")

    for i <- 1..3 do
      {:ok, n} = Notes.upsert_note(u, v, %{"path" => "t#{i}.md", "content" => "t"}, actor: "api")
      Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(n.id)])
    end

    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "live.md", "content" => "l"}, actor: "api")

    counts = for _ <- 1..3, do: BackfillCrdtHead.enqueue_all()
    assert Enum.sum(counts) >= 1, "the live note never became a candidate: #{inspect(counts)}"
  end

  # A head cleared by an append is found by the next run through the note's
  # write, whatever the key window's position.
  test "a note written since the last run is a candidate outside the key window", %{
    user: u,
    vault: v
  } do
    Application.put_env(:engram, :crdt_head_candidate_cap, 1)
    on_exit(fn -> Application.delete_env(:engram, :crdt_head_candidate_cap) end)

    for i <- 1..5,
        do:
          {:ok, _} =
            Notes.upsert_note(u, v, %{"path" => "k#{i}.md", "content" => "k"}, actor: "api")

    head = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    Repo.query!("UPDATE notes SET crdt_head = $1, updated_at = now() - interval '1 day'", [head])
    assert BackfillCrdtHead.enqueue_all() == 0

    %{rows: [[last]]} = Repo.query!("SELECT id FROM notes ORDER BY id DESC LIMIT 1")
    Repo.query!("UPDATE notes SET crdt_head = NULL, updated_at = now() WHERE id = $1", [last])
    assert BackfillCrdtHead.enqueue_all() == 1
  end
end
