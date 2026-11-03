defmodule EngramWeb.SyncManifestPlanTest do
  # Guard: the sync manifest and the attachment usage sum read indexes only.
  #
  # Prod 2026-11-02 (engram_app, RLS set), a 40k-note vault: the notes half
  # read every notes heap row (40k buffers, 78 ms) and hash-joined every
  # note_bodies heap row of the user for `crdt_head` (40k buffers, 8k disk
  # reads, 604 ms): 839 ms in all. The attachments half (14.8k rows) did a
  # bitmap heap scan with 1,885 disk reads (38 ms), and the per-user usage sum
  # read the same 2,307 heap pages (10 ms, 203k calls in 5 days).
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

  test "the manifest's notes read is index-only on notes and note_bodies", %{conn: conn} do
    [sql] =
      for sql <- statements(manifest(conn), "notes"),
          sql =~ ~s|uuid_send(n0."id")|,
          do: sql

    plan = plan(sql)
    assert plan =~ "Index Only Scan using notes_manifest", plan
    assert plan =~ "Index Only Scan using note_bodies_user_note_head", plan
  end

  test "the manifest's attachments read is index-only", %{conn: conn} do
    [sql] =
      for sql <- statements(manifest(conn), "attachments"),
          sql =~ ~s|uuid_send(a0."id")|,
          do: sql

    assert plan(sql) =~ "Index Only Scan using attachments_manifest"
  end

  test "the per-user attachment usage sum is index-only", %{user: user} do
    [sql] = statements(fn -> {:ok, _} = Attachments.storage_usage(user) end, "attachments")
    assert plan(sql) =~ "Index Only Scan using attachments_user_live_size"
  end
end
