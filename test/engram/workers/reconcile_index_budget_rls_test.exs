defmodule Engram.Workers.ReconcileIndexBudgetRlsTest do
  @moduledoc """
  The per-note cap sweep and the index points budget sweep select across
  tenants (adversarial V5). The rest of their suite runs as the test
  superuser, where RLS never applies, so this proves the selection under
  the prod roles (`docs/context/rls-enforcement-testing-traps.md`):

    * CONTROL: the app pool, as `engram_app` with no tenant, sees zero notes.
    * The maintenance pool connects as `engram_maintenance` (no bypass, only
      the `maintenance_all` policies) and finds exactly the right notes. A
      Starter user's 129-chunk note staying unselected is the proof that
      `subscriptions` is visible to it: hidden, every paid user resolves to
      Free in SQL and is re-merged every day.
    * Without a maintenance pool, the over-cap sweep's per-tenant fallback
      still finds the Free note under `engram_app`.

  The maintenance pool is its own connection, so the rows are COMMITTED and
  deleted on exit. The sweeps run under the ROLLING-BACK `as_prod_role/1`
  and report what they enqueued from inside it: their app-pool writes
  (backoff stamps, tier stamps) would otherwise hold row locks on the
  committed rows until the sandbox owner exits, after the cleanup runs.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.RlsCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Workers.{RebuildStaleNote, ReconcileEmbeddings}

  @moduletag :rls_unsafe

  @email_prefix "reconcile-index-budget-rls-"

  setup do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    # A green collection: the budget sweep pauses on red or unreachable.
    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": {"status": "green"}}))
    end)

    delete_committed!()
    on_exit(&delete_committed!/0)

    seeded =
      Sandbox.unboxed_run(Repo, fn ->
        free = seed_user("free", 129)
        starter = seed_user("starter", 129)
        insert(:subscription, user: starter.user, tier: "starter", status: "active")
        # Over a lowered points cap (30 rows > 20), under every per-note cap.
        budget = seed_user("budget", 30)

        insert(:user_limit_override,
          user: budget.user,
          key: "index_points_cap",
          value: %{"v" => 20}
        )

        %{free: free, starter: starter, budget: budget}
      end)

    Engram.Billing.OverrideCache.evict(seeded.budget.user.id)
    seeded
  end

  defp with_maintenance_role do
    config =
      Keyword.merge(Repo.config(),
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        after_connect: {Postgrex, :query!, ["SET SESSION AUTHORIZATION engram_maintenance", []]}
      )

    start_supervised!({Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)
  end

  # A Free-tier dense note at its content with `rows` chunk rows.
  defp seed_user(tag, rows) do
    email = "#{@email_prefix}#{tag}-#{System.unique_integer([:positive])}@t.co"
    user = insert(:user, email: email)
    vault = insert(:vault, user: user)
    note = Engram.Fixtures.insert_note!(user, vault, path: "#{tag}.md", content: "# #{tag}")

    Repo.update_all(
      from(n in Note,
        where: n.id == ^note.id,
        update: [set: [embed_hash: n.content_hash, dense_indexed_hash: n.content_hash]]
      ),
      # Current keyword version too: the keyword sweep's maintenance UPDATE
      # would otherwise wait on the budget sweep's tier stamp, which the
      # sandbox holds uncommitted (a deadlock only this harness has).
      [
        set: [
          chunker_version: Markdown.chunker_version(),
          keyword_version: Engram.KeywordIndex.version()
        ]
      ],
      skip_tenant_check: true
    )

    Repo.query!(
      """
      INSERT INTO chunks
        (note_id, user_id, vault_id, position, char_start, char_end, qdrant_point_id,
         created_at, token_count, context_hmac)
      SELECT $1, $2, $3, g, 0, 1, gen_random_uuid(), now(), 1, 'h'
      FROM generate_series(0, $4 - 1) g
      """,
      [Ecto.UUID.dump!(note.id), Ecto.UUID.dump!(user.id), Ecto.UUID.dump!(vault.id), rows]
    )

    %{user: user, note: note}
  end

  defp delete_committed! do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '5s'")

        ids =
          from(u in Engram.Accounts.User,
            where: like(u.email, ^"#{@email_prefix}%"),
            select: u.id
          )

        Repo.delete_all(from(n in Note, where: n.user_id in subquery(ids)),
          skip_tenant_check: true
        )

        Repo.delete_all(ids |> exclude(:select), skip_tenant_check: true)
      end)
    end)
  end

  defp reverify_tick, do: DateTime.new!(Date.utc_today(), ~T[04:02:00])

  defp recap_note_ids do
    for j <- all_enqueued(worker: RebuildStaleNote),
        j.args["recap"] == true,
        do: j.args["note_id"]
  end

  test "CONTROL: the app role with no tenant sees none of the notes" do
    assert {:returned, 0} =
             as_prod_role(fn -> Repo.aggregate(Note, :count, skip_tenant_check: true) end)
  end

  test "the maintenance role selects the Free note over its per-note cap, not the Starter one",
       %{free: free} do
    with_maintenance_role()

    assert {:returned, [free_id]} =
             as_prod_role(fn ->
               :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
               recap_note_ids()
             end)

    assert free_id == free.note.id
  end

  test "the maintenance role finds the user over the points budget", %{budget: budget} do
    with_maintenance_role()

    assert {:returned, {{:ok, %{demoted: 1}}, tier}} =
             as_prod_role(fn ->
               result = ReconcileEmbeddings.budget_sweep(20)

               {:ok, tier} =
                 Repo.with_tenant(budget.user.id, fn ->
                   Repo.one(from(n in Note, where: n.id == ^budget.note.id, select: n.index_tier))
                 end)

               {result, tier}
             end)

    assert tier in ["floor", "floor_paid"]
  end

  test "without a maintenance pool, the per-tenant fallback still finds the Free note", %{
    free: free
  } do
    assert {:returned, [free_id]} =
             as_prod_role(fn ->
               :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
               recap_note_ids()
             end)

    assert free_id == free.note.id
  end
end
