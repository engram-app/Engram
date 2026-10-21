defmodule Engram.NotesPathIndexPlanTest do
  # Guard: every lookup of a live note by path can use the path index.
  #
  # The only index on `path_hmac` for live rows is the partial
  # `notes_user_vault_path_v2 ... WHERE deleted_at IS NULL AND kind = 'note'`.
  # Postgres uses a partial index only when the query's WHERE implies its
  # predicate, and it does not consult CHECK constraints for that proof. So a
  # lookup without `kind = 'note'` cannot use it and filters the whole vault
  # row by row instead (2026-10-20 audit, P0-1). Folder markers have
  # `path_hmac IS NULL` by `notes_kind_shape_check`, so adding the kind filter
  # changes no result.
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.QueryPlan
  alias Engram.QueryRecorder

  @live_index "notes_user_vault_path_v2"
  @tomb_index "notes_vault_path_tombstone_index"

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "a"}, actor: "api")
    {:ok, _} = Notes.create_folder_marker(user, vault, "Folder")
    # A vault with more than a handful of notes, so the planner's choice
    # reflects selectivity rather than a near-empty table's cost ties.
    for _ <- 1..300, do: insert(:note, user: user, vault: vault)
    %{user: user, vault: vault}
  end

  defp path_lookups(fun) do
    {_result, queries} = QueryRecorder.record(fun)

    for sql <- QueryPlan.reading(queries, "notes"),
        String.starts_with?(sql, "SELECT"),
        sql =~ ~r/"path_hmac" = (ANY\()?\$\d/,
        do: sql
  end

  defp assert_index(sqls, index) do
    assert sqls != [], "recorded no path lookup on notes; the test no longer reaches it"

    for sql <- sqls do
      # `= ANY($n)` is costed as 10 index descents; on 300 rows one bitmap over
      # the vault via another (user_id, vault_id, ...) index can cost less, and
      # which one wins flips with ANALYZE's sample. A prod vault spans far more
      # pages, so the bitmap is ruled out here rather than outvoted.
      plan = QueryPlan.generic_plan(sql, analyze: ["notes"], bitmapscan: false)
      assert plan =~ index, "expected #{index} to serve:\n#{sql}\n\nplan:\n#{plan}"
    end
  end

  test "note_exists?/3 (note_by_path_query) uses the live path index", %{user: u, vault: v} do
    assert_index(path_lookups(fn -> assert Notes.note_exists?(u, v, "A.md") end), @live_index)
  end

  test "note_ids_for_paths/3 uses the live path index, with and without a vault", ctx do
    %{user: u, vault: v} = ctx
    assert_index(path_lookups(fn -> Notes.note_ids_for_paths(u, v, ["A.md"]) end), @live_index)
    assert_index(path_lookups(fn -> Notes.note_ids_for_paths(u, nil, ["A.md"]) end), @live_index)
  end

  test "rename's claim check (note_ids_at) uses the live path index", %{user: u, vault: v} do
    sqls = path_lookups(fn -> {:ok, _} = Notes.rename_note(u, v, "A.md", "B.md") end)
    assert_index(sqls, @live_index)
  end

  test "the delete-wins resurrection check uses the tombstone path index", %{user: u, vault: v} do
    :ok = Notes.delete_note(u, v, "A.md")

    {_, queries} =
      QueryRecorder.record(fn ->
        Notes.upsert_note(u, v, %{"path" => "A.md", "content" => "a"}, actor: "api")
      end)

    sqls =
      for sql <- QueryPlan.reading(queries, "notes"),
          sql =~ ~s("content_hash" = $) and sql =~ ~s(NOT \(n0."deleted_at" IS NULL\)),
          do: sql

    assert_index(sqls, @tomb_index)
  end

  describe "results are unchanged by the kind filter" do
    test "live notes resolve, tombstones and folder markers do not", %{user: u, vault: v} do
      {:ok, b} = Notes.upsert_note(u, v, %{"path" => "B.md", "content" => "b"}, actor: "api")
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "C.md", "content" => "c"}, actor: "api")
      :ok = Notes.delete_note(u, v, "C.md")

      assert %{"B.md" => id} = Notes.note_ids_for_paths(u, v, ["B.md", "C.md", "Nope.md"])
      assert id == b.id
      assert Notes.note_ids_for_paths(u, nil, ["C.md"]) == %{}
      assert Notes.note_exists?(u, v, "B.md")
      refute Notes.note_exists?(u, v, "C.md")
    end
  end
end
