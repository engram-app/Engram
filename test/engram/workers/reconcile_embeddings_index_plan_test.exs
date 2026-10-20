defmodule Engram.Workers.ReconcileEmbeddingsIndexPlanTest do
  # Guard: the 5-minute reconcile sweep reads an index, not the whole table.
  #
  # Its filter is `kind = 'note' AND deleted_at IS NULL AND (embed_hash IS NULL
  # OR embed_hash <> content_hash OR dense_indexed_hash IS NULL)` ordered by
  # updated_at. `idx_notes_embed_pending` could not serve it (no arm for
  # `dense_indexed_hash IS NULL`), so every tick was a seq scan plus a top-N
  # sort of every note, even with nothing to do: 39 ms mean at 35k notes in
  # prod, linear in total notes (2026-10-20 audit, P0-2). `notes_reconcile_due`
  # carries exactly that predicate, keyed on updated_at so LIMIT stops early.
  #
  # Only when IndexVersions is done: while a version is open the version arm
  # (a parameter) is in the OR and no partial index can be implied. That is
  # the rare case and is left alone here.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.DataMigrations
  alias Engram.DataMigrations.IndexVersions
  alias Engram.QueryPlan
  alias Engram.QueryRecorder
  alias Engram.Workers.ReconcileEmbeddings

  setup do
    DataMigrations.reset_cache()
    :ok = DataMigrations.mark_done(IndexVersions.name(), 1)
    on_exit(&DataMigrations.reset_cache/0)
  end

  test "the sweep UPDATE's eligible subquery uses notes_reconcile_due" do
    user = insert(:user)
    note = insert(:note, user: user, vault: insert(:vault, user: user), embed_hash: nil)

    tick = DateTime.new!(Date.utc_today(), ~T[03:57:00])

    {_, queries} =
      QueryRecorder.record(fn ->
        assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: tick)
      end)

    assert_enqueued(worker: Engram.Workers.EmbedNote, args: %{"note_id" => note.id})

    sweeps = for %{sql: "UPDATE \"notes\"" <> _ = sql} <- queries, do: sql
    assert [sql | _] = sweeps, "recorded no reconcile UPDATE on notes"

    plan = QueryPlan.generic_plan(sql)
    assert plan =~ "notes_reconcile_due", "plan:\n#{plan}\n\nsql:\n#{sql}"
  end
end
