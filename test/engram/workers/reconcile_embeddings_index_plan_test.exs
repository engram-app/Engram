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
  #
  # The table is seeded in prod's shape (the vault's notes mostly indexed, one
  # due) and ANALYZEd before the EXPLAIN. On a one-row table the partial index
  # and a `notes_folder` scan of the vault cost the same to within 1% (16.32 vs
  # 16.46), so the plan followed whatever stats the shared test DB held from
  # earlier tests, and CI picked `notes_folder` on some runs.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.DataMigrations
  alias Engram.DataMigrations.IndexVersions
  alias Engram.QueryPlan
  alias Engram.QueryRecorder
  alias Engram.Workers.ReconcileEmbeddings

  # Indexed notes beside the one due: enough that scanning the vault costs
  # clearly more than the partial index.
  @indexed 200
  @small_vaults 400

  setup do
    DataMigrations.reset_cache()
    :ok = DataMigrations.mark_done(IndexVersions.name(), 1)
    on_exit(&DataMigrations.reset_cache/0)
  end

  test "the sweep UPDATE's eligible subquery uses notes_reconcile_due" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault, embed_hash: nil)

    done = :crypto.hash(:sha256, "# Test note content") |> Base.encode16(case: :lower)

    insert_list(@indexed, :note,
      user: user,
      vault: vault,
      embed_hash: done,
      dense_indexed_hash: done
    )

    tick = DateTime.new!(Date.utc_today(), ~T[03:57:00])

    {_, queries} =
      QueryRecorder.record(fn ->
        assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: tick)
      end)

    assert_enqueued(worker: Engram.Workers.EmbedNote, args: %{"note_id" => note.id})

    # The eligible ids are a materialized CTE in front of the UPDATE.
    sweeps = for %{sql: "WITH \"reconcile_eligible\"" <> _ = sql} <- queries, do: sql
    assert [sql | _] = sweeps, "recorded no reconcile UPDATE on notes"

    plan = QueryPlan.generic_plan(sql, analyze: ~w(notes vaults))
    assert plan =~ "notes_reconcile_due", "plan:\n#{plan}\n\nsql:\n#{sql}"
  end

  # The windowed sweep (an IndexVersions rollout, and the daily re-verify)
  # names one id window of notes. Prod E5 (2026-11-02, as engram_app under
  # the tenant): with the vault as an INNER JOIN the planner drove the loop
  # from the user's vaults and scanned `notes_recent_index (user_id,
  # vault_id, updated_at, id)` once per vault, filtering the window's ids
  # against every note of the vault: 445 ms, 669 cold reads, for 5 ids.
  # The window must be fetched by primary key, under RLS (self-host's
  # per-user walk, the E5 shape) and without it (SaaS' fleet walk).
  # Seeds 400 users: slow on a loaded runner.
  @tag timeout: 180_000
  test "the windowed sweep fetches its id window by primary key, not per vault" do
    user = insert(:user)
    vaults = insert_list(2, :vault, user: user)
    done = :crypto.hash(:sha256, "# Test note content") |> Base.encode16(case: :lower)

    for vault <- vaults,
        do:
          insert_list(@indexed, :note,
            user: user,
            vault: vault,
            embed_hash: done,
            dense_indexed_hash: done
          )

    note = insert(:note, user: user, vault: hd(vaults), embed_hash: nil)

    # Prod's shape: many small vaults, so the statistics put a few notes in
    # any one vault and a per-vault index scan looks as cheap as the window's
    # primary-key probes, though this user's vaults hold hundreds.
    for _ <- 1..@small_vaults do
      other = insert(:user)

      insert_list(1, :note,
        user: other,
        vault: insert(:vault, user: other),
        embed_hash: done,
        dense_indexed_hash: done
      )
    end

    # A version rollout is open (the test config opens the Qdrant gate): the
    # version term is on, so the sweep walks id windows.
    :ok = DataMigrations.reopen(IndexVersions.name(), 1)
    DataMigrations.reset_cache()

    tick = DateTime.new!(Date.utc_today(), ~T[03:57:00])

    {_, queries} =
      QueryRecorder.record(fn ->
        assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: tick)
      end)

    assert_enqueued(worker: Engram.Workers.EmbedNote, args: %{"note_id" => note.id})

    windowed =
      for %{sql: "WITH \"reconcile_eligible\"" <> _ = sql} <- queries,
          sql =~ "ANY(" or sql =~ "unnest(",
          do: sql

    assert [sql | _] = windowed, "recorded no windowed reconcile UPDATE on notes"

    Repo.query!("ANALYZE notes")
    Repo.query!("ANALYZE vaults")

    fleet = QueryPlan.generic_plan(sql)
    tenant = Repo.with_tenant!(user.id, fn -> QueryPlan.generic_plan(sql) end)

    # Only the window fetch (the CTE): the outer UPDATE always probes
    # `notes_pkey` by the CTE's ids, which says nothing about how the window
    # was read. Any other notes index there (`notes_recent_index` per vault,
    # `idx_notes_user_created_rank` per user) has `id` as a late column, so
    # it reads every note of the vault or user to find the window's ids.
    for plan <- [fleet, tenant] do
      window = window_fetch(plan)
      msg = "window fetch:\n#{window}\n\nplan:\n#{plan}\n\nsql:\n#{sql}"
      assert window =~ "notes_pkey", msg
      refute window =~ ~r/Scan using (?!notes_pkey\b)\S+ on notes\b/, msg
      refute window =~ ~r/Bitmap Index Scan on (?!notes_pkey\b)(idx_)?notes/, msg
      refute window =~ "Seq Scan on notes", msg
    end
  end

  # The `CTE reconcile_eligible` subtree of a plan: its header line, then
  # every line indented deeper than the main statement's nodes.
  defp window_fetch(plan) do
    plan
    |> String.split("\n")
    |> Enum.drop_while(&(not (&1 =~ "CTE reconcile_eligible")))
    |> Enum.drop(1)
    |> Enum.take_while(&String.starts_with?(&1, "    "))
    |> Enum.join("\n")
  end
end
