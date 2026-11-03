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
  defp plan(sql) do
    for t <- @tables do
      Engram.Repo.query!("REINDEX TABLE #{t}")
      Engram.Repo.query!("ANALYZE #{t}")
    end

    Engram.Repo.query!(
      "UPDATE pg_class SET relallvisible = relpages WHERE relname = ANY($1) AND relnamespace = 'public'::regnamespace",
      [@tables]
    )

    QueryPlan.generic_plan(sql, bitmapscan: false)
  end

  test "the manifest reads crdt_head index-only from note_bodies", %{conn: conn} do
    [sql] =
      for sql <- statements(manifest(conn), "notes"),
          sql =~ ~s|uuid_send(n0."id")|,
          do: sql

    plan = plan(sql)
    assert plan =~ "Index Only Scan using note_bodies_user_note_head", plan
  end

  test "the per-user attachment usage sum is index-only", %{user: user} do
    [sql] = statements(fn -> {:ok, _} = Attachments.storage_usage(user) end, "attachments")
    assert plan(sql) =~ "Index Only Scan using attachments_user_live_size"
  end
end
