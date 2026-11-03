defmodule EngramWeb.SyncManifestPlanTest do
  # Guard: the sync manifest reads `crdt_head` from an index only, and the
  # attachment usage sum reads an index only.
  #
  # Prod 2026-11-02 (engram_app, RLS set), a 40k-note vault: the notes half
  # read every notes heap row (40k buffers, all cached, 78 ms) and hash-joined
  # every note_bodies heap row of the user for `crdt_head` (40k buffers, 8k
  # disk reads, 604 ms): 839 ms in all. The per-user usage sum read 2,307
  # attachments heap pages (10 ms, 203k calls in 5 days). The notes and
  # attachments heap reads stay: no index carries the uncapped
  # `path_ciphertext` (a btree entry over ~2.7 KB would refuse the write).
  #
  # The plan asserted is the generic one with seq scans off
  # (`Engram.QueryPlan`): the question is whether the covering indexes
  # answer every column, so no heap page is read for an all-visible row.
  # Not async: the test rebuilds three tables' indexes and writes their
  # `pg_class` statistics (both rolled back with the sandbox).
  use EngramWeb.ConnCase, async: false

  alias Engram.Attachments
  alias Engram.QueryPlan
  alias Engram.QueryRecorder

  @tables ~w(notes note_bodies attachments)

  setup %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "a"}, actor: "api")

    for _ <- 1..300, do: insert(:note, user: user, vault: vault)
    for _ <- 1..300, do: insert(:attachment, user: user, vault: vault)
    # A second vault, so the usage sum's `user_id` prefix spans vaults.
    other = insert(:vault, user: user)
    for _ <- 1..50, do: insert(:attachment, user: user, vault: other)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user}
  end

  defp statements(fun, table) do
    {_, queries} = QueryRecorder.record(fun)
    QueryPlan.reading(queries, table)
  end

  # The decoy rows carry random path ciphertext, so the render after the
  # read raises; only the statement the read sent is wanted here.
  defp manifest(conn) do
    fn ->
      assert_raise RuntimeError, ~r/path decrypt failed/, fn ->
        get(conn, "/api/sync/manifest")
      end
    end
  end

  # Statistics as prod has them. REINDEX: a sandbox rolls its rows back, so
  # an index carries every earlier test's dead entries until a vacuum (64
  # pages for 300 rows here), which only a rebuild drops. ANALYZE, then the
  # visibility map counted as set: a sandbox cannot VACUUM, and with no
  # all-visible page every index-only scan is costed as a heap fetch per
  # row. Prod's cold rows are all-visible.
  defp plan(sql, tenant \\ nil) do
    for t <- @tables do
      Engram.Repo.query!("REINDEX TABLE #{t}")
      Engram.Repo.query!("ANALYZE #{t}")
    end

    Engram.Repo.query!(
      "UPDATE pg_class SET relallvisible = relpages WHERE relname = ANY($1) AND relnamespace = 'public'::regnamespace",
      [@tables]
    )

    if tenant,
      do:
        Engram.Repo.with_tenant!(tenant, fn -> QueryPlan.generic_plan(sql, bitmapscan: false) end),
      else: QueryPlan.generic_plan(sql, bitmapscan: false)
  end

  defp manifest_notes_sql(conn) do
    [sql] = for sql <- statements(manifest(conn), "notes"), sql =~ ~s|uuid_send(n0."id")|, do: sql
    sql
  end

  test "the manifest reads crdt_head index-only from note_bodies", %{conn: conn} do
    plan = plan(manifest_notes_sql(conn))
    assert plan =~ "Index Only Scan using note_bodies_user_note_head", plan
  end

  # Prod 2026-11-03, the same 40k-note vault cold: the notes side read 9.3k
  # heap pages (5.5 s at ~0.56 ms a read), about 5 rows a page. Under the
  # tenant's generic plan (what a 6th or later call may run) the notes side
  # is an index-only scan of `notes_manifest`, about 1.4k leaf pages for that
  # vault. Rows whose path ciphertext is too long for a btree entry come from
  # `notes_manifest_long_path`; the no-body head fallback probes `notes_pkey`
  # per row. No other notes index and no heap scan of the vault.
  test "the manifest's notes side is index-only on notes_manifest under a tenant", ctx do
    plan = plan(manifest_notes_sql(ctx.conn), ctx.user.id)
    assert plan =~ "Index Only Scan using notes_manifest on notes", plan

    refute plan =~
             ~r/Scan(?: Backward)? using (?!notes_manifest(?:_long_path)?\b|notes_pkey\b)\S+ on notes\b/,
           plan

    refute plan =~ ~r/(Seq|Bitmap Heap) Scan on notes\b/, plan

    # Index-only skips the heap only for all-visible pages: notes vacuums
    # often enough to keep its visibility map set.
    %{rows: [[opts]]} =
      Engram.Repo.query!("SELECT reloptions FROM pg_class WHERE oid = 'notes'::regclass")

    assert "autovacuum_vacuum_scale_factor=0.02" in opts
    assert "autovacuum_vacuum_insert_scale_factor=0.02" in opts
  end

  test "the per-user attachment usage sum is index-only", %{user: user} do
    [sql] = statements(fn -> {:ok, _} = Attachments.storage_usage(user) end, "attachments")
    assert plan(sql) =~ "Index Only Scan using attachments_user_live_size"
  end
end
