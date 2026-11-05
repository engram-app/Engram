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
  alias Engram.Notes.Note
  alias Engram.QueryPlan
  alias Engram.QueryRecorder
  alias Engram.Workers.EmbedNote
  alias Engram.Workers.ReconcileEmbeddings

  # Indexed notes beside the one due: enough that scanning the vault costs
  # clearly more than the partial index.
  @indexed 200
  @small_vaults 400
  @done :crypto.hash(:sha256, "# Test note content") |> Base.encode16(case: :lower)
  @other_tenants 50

  setup do
    DataMigrations.reset_cache()
    :ok = DataMigrations.mark_done(IndexVersions.name(), 1)
    on_exit(&DataMigrations.reset_cache/0)
  end

  test "the sweep UPDATE's eligible subquery uses notes_reconcile_due" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault, embed_hash: nil)

    insert_list(@indexed, :note,
      user: user,
      vault: vault,
      embed_hash: @done,
      dense_indexed_hash: @done
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

    plan = QueryPlan.generic_plan(sql, analyze: ~w(notes vaults), fresh: true)
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
    {user, vaults} = seed_prod_shape()
    note = insert(:note, user: user, vault: hd(vaults), embed_hash: nil)

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
    for plan <- [fleet, tenant], do: assert_pk_only(window_fetch(plan), plan, sql)
  end

  # The other two id-window discovery reads: `DataMigrations.any_row?/1`
  # (IndexVersions' done check) and `IdWindows.all/2` (the CRDT head and
  # state backfills, whose vault INNER JOIN is the E5 shape). Each window
  # statement reads `notes` only by primary key, under the tenant's RLS
  # (the per-user walk the test pool runs) and without it.
  @tag timeout: 180_000
  test "any_row? and IdWindows.all fetch their id window by primary key" do
    {user, _vaults} = seed_prod_shape()

    {_, queries} =
      QueryRecorder.record(fn ->
        IndexVersions.run_pass()
        Engram.Workers.BackfillCrdtHead.enqueue_all()
        Engram.Workers.BackfillCrdtState.enqueue_missing()
      end)

    windowed =
      queries
      |> QueryPlan.reading("notes")
      |> Enum.filter(&(&1 =~ "ANY(" or &1 =~ "unnest("))
      |> Enum.uniq()

    any_row = for "SELECT TRUE" <> _ = sql <- windowed, do: sql
    all = for "SELECT DISTINCT" <> _ = sql <- windowed, do: sql
    assert [_] = any_row, "recorded no any_row? window read:\n#{Enum.join(windowed, "\n")}"
    assert [_, _] = all, "recorded no IdWindows.all window reads:\n#{Enum.join(windowed, "\n")}"

    Repo.query!("ANALYZE notes")
    Repo.query!("ANALYZE vaults")

    for sql <- any_row ++ all do
      assert_pk_only(QueryPlan.generic_plan(sql), sql)
      assert_pk_only(Repo.with_tenant!(user.id, fn -> QueryPlan.generic_plan(sql) end), sql)
    end
  end

  # One user with two vaults of @indexed indexed notes, beside
  # @small_vaults one-note users. Prod's shape: many small vaults, so the
  # statistics put a few notes in any one vault (or user) and a per-vault
  # index scan looks as cheap as the window's primary-key probes, though
  # this user's vaults hold hundreds.
  defp seed_prod_shape do
    user = insert(:user)
    vaults = insert_list(2, :vault, user: user)

    for vault <- vaults,
        do:
          insert_list(@indexed, :note,
            user: user,
            vault: vault,
            embed_hash: @done,
            dense_indexed_hash: @done
          )

    for _ <- 1..@small_vaults do
      other = insert(:user)

      insert(:note,
        user: other,
        vault: insert(:vault, user: other),
        embed_hash: @done,
        dense_indexed_hash: @done
      )
    end

    {user, vaults}
  end

  # `notes` is read through `notes_pkey` and no other notes index: any other
  # (`notes_recent_index` per vault, `idx_notes_user_created_rank` per user)
  # has `id` as a late column, so it reads every note of the vault or user
  # to find the window's ids.
  defp assert_pk_only(part, plan \\ nil, sql) do
    msg = "window fetch:\n#{part}\n\nplan:\n#{plan || part}\n\nsql:\n#{sql}"
    assert part =~ "notes_pkey", msg
    refute part =~ ~r/Scan using (?!notes_pkey\b)\S+ on notes\b/, msg
    refute part =~ ~r/Bitmap Index Scan on (?!notes_pkey\b)(idx_)?notes/, msg
    refute part =~ "Seq Scan on notes", msg
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

  # A Free note parked on the embed bucket waits for `WakeBudgetParked`, at
  # the time its bucket can pay. In `notes_reconcile_due` it still sat in the
  # backlog predicate (no dense vectors), so every sweep read and rejected it
  # (prod 2026-11-02: 1,662 entries, all parked). `notes_reconcile_due_v2`
  # leaves out a parked note whose content is unchanged, so a sweep reads the
  # notes that can be due, not every parked one. On the 7th run, custom and
  # generic plan alike, with seq scans off: the planner costs the sweep as
  # matching most of the table (`embed_hash <> content_hash` is a default
  # 0.995), so on a test-sized table a seq scan and sort can win, and did on
  # CI once an earlier test had ANALYZEd an empty `subscriptions` (its
  # EXISTS then costs 0). What is asserted is that v2 CAN serve the sweep.
  test "the sweep reads notes_reconcile_due_v2, which holds no unchanged park" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    # An empty bucket: the sweep's backstop wake leaves the parks parked.
    insert(:user_limit_override, user: user, key: "embed_token_bucket", value: %{"v" => 0})

    insert_list(@indexed, :note,
      user: user,
      vault: vault,
      embed_hash: @done,
      dense_indexed_hash: @done
    )

    parked =
      insert_list(@indexed, :note,
        user: user,
        vault: vault,
        embed_hash: @done,
        dense_indexed_hash: nil,
        embed_budget_parked: true,
        embed_budget_parked_at: DateTime.utc_now(),
        embed_retry_after: EmbedNote.parked_until_edited()
      )

    due = insert(:note, user: user, vault: vault, embed_hash: nil)

    # Other tenants' indexed notes: a table of many vaults, as prod's is.
    for _ <- 1..@other_tenants do
      other = insert(:user)

      insert_list(20, :note,
        user: other,
        vault: insert(:vault, user: other),
        embed_hash: @done,
        dense_indexed_hash: @done
      )
    end

    # Only this test's rows: earlier tests in the partition leave dead pages
    # that flipped this plan to a seq scan on CI (QueryPlan.generic_plan/2).
    QueryPlan.fresh!("notes")
    QueryPlan.fresh!("vaults")

    tick = DateTime.new!(Date.utc_today(), ~T[03:57:00])

    %{custom: custom, generic: generic} =
      QueryPlan.after_runs(
        fn -> assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: tick) end,
        ~r/^WITH "reconcile_eligible"/,
        seqscan: false
      )

    assert_enqueued(worker: EmbedNote, args: %{"note_id" => due.id})

    for plan <- [custom, generic] do
      assert plan =~ "notes_reconcile_due_v2", plan
      refute plan =~ ~r/notes_reconcile_due\b(?!_v2)/, plan
    end

    # The parks were never stamped: no sweep picked them.
    ids = Enum.map(parked, & &1.id)

    assert [EmbedNote.parked_until_edited()] ==
             Repo.all(
               from(n in Note,
                 where: n.id in ^ids,
                 distinct: true,
                 select: n.embed_retry_after
               ),
               skip_tenant_check: true
             )

    refute_enqueued(worker: EmbedNote, args: %{"note_id" => hd(ids)})
  end

  # The index leaves a park out only while its content is unchanged: an
  # edited one stays in it, so a sweep still finds it when the edit's own
  # job was lost.
  test "an edited park stays in notes_reconcile_due_v2 and is swept" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    insert(:user_limit_override, user: user, key: "embed_token_bucket", value: %{"v" => 0})

    edited =
      insert(:note,
        user: user,
        vault: vault,
        embed_hash: "old",
        dense_indexed_hash: nil,
        embed_budget_parked: true,
        embed_budget_parked_at: DateTime.utc_now(),
        embed_retry_after: EmbedNote.parked_until_edited()
      )

    assert :ok = perform_job(ReconcileEmbeddings, %{})
    assert_enqueued(worker: EmbedNote, args: %{"note_id" => edited.id})
  end
end
