defmodule Engram.NotesGenericPlanTest do
  # Guard: a lookup of `notes` by key never runs on a GENERIC plan.
  #
  # Postgrex prepares a named statement per query shape; from the 6th
  # execution Postgres may switch it to a generic plan, costed for an average
  # vault. Prod 2026-11-02 (engram_app, RLS set): the path lookup's generic
  # plan chose `notes_recent_index (user_id, vault_id, ...)` and filtered
  # `path_id` row by row over a 40k-note vault (12,665 buffers a call, 130k
  # calls in 5 days), while its custom plan read `notes_path_live` (3
  # buffers). `Engram.Notes.Keys.lookup?/1` + `Engram.Repo.prepare_query/3`
  # run every such lookup unnamed, so each call gets a custom plan.
  #
  # Each test runs the real call 7 times on the sandbox connection, then reads
  # `pg_prepared_statements.generic_plans` for its SQL (a named statement that
  # went generic) and the custom plan for the recorded values.
  #
  # The tenancy shape is set with `ALTER COLUMN ... SET (n_distinct = 40)`:
  # the planner sees 40 tenants, as prod sees hundreds, so a generic
  # `vault_id = $2` is a fraction of this vault (on main, this setup
  # reproduces the prod plan exactly). Not async: ALTER TABLE locks `notes`
  # until the sandbox rolls back.
  use Engram.DataCase, async: false

  alias Engram.DataMigrations
  alias Engram.Links
  alias Engram.Notes
  alias Engram.QueryRecorder
  alias Engram.Repo

  setup do
    on_exit(fn ->
      Engram.Cache.clear_local(:note_split)
      DataMigrations.reset_cache()
    end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Big", Ecto.UUID.generate())

    for path <- ["A.md", "F/one.md"] do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")
    end

    for _ <- 1..1000 do
      insert(:note,
        user: user,
        vault: vault,
        path_hmac: :crypto.strong_rand_bytes(32),
        folder_hmac: :crypto.strong_rand_bytes(32),
        basename_hmac: :crypto.strong_rand_bytes(32)
      )
    end

    Repo.query!("ALTER TABLE notes ALTER COLUMN user_id SET (n_distinct = 40)")
    Repo.query!("ALTER TABLE notes ALTER COLUMN vault_id SET (n_distinct = 40)")
    Repo.query!("ANALYZE notes")

    :ok = DataMigrations.mark_done("note_split", 1)
    Engram.Cache.clear_local(:note_split)
    assert Notes.Keys.ids?()

    %{user: user, vault: vault}
  end

  # Runs `fun` 7 times (past the 5 custom plans Postgres tries first), then
  # returns the plan the matching statement ran on: fails if any named
  # statement with its SQL went generic, else the custom plan for its values.
  defp plan_of(fun, pattern) do
    %{sql: sql, params: params} =
      for(_ <- 1..7, do: record(fun, pattern)) |> List.last()

    %{rows: [[generic]]} =
      Repo.query!(
        "SELECT coalesce(sum(generic_plans), 0)::int FROM pg_prepared_statements WHERE statement = $1",
        [sql]
      )

    assert generic == 0, "ran on a generic plan #{generic} times:\n#{sql}"

    Repo.query!("EXPLAIN " <> inline(sql, params)).rows |> List.flatten() |> Enum.join("\n")
  end

  defp record(fun, pattern) do
    {_, queries} = QueryRecorder.record(fun)
    me = self()
    [q | _] = for %{pid: ^me, sql: sql} = q <- queries, sql =~ pattern, do: q
    q
  end

  # The statement with its recorded values in place of $n (highest first, so
  # $1 does not eat $10): a one-off EXPLAIN plans it as a custom plan would.
  defp inline(sql, params) do
    params
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.reduce(sql, fn {v, i}, acc -> String.replace(acc, "$#{i}", literal(v)) end)
  end

  defp literal(list) when is_list(list),
    do: "ARRAY[" <> Enum.map_join(list, ", ", &literal/1) <> "]"

  defp literal(<<_::binary-16>> = uuid), do: "'#{Ecto.UUID.load!(uuid)}'::uuid"
  defp literal(v) when is_integer(v), do: Integer.to_string(v)
  defp literal(v) when is_binary(v), do: "'" <> String.replace(v, "'", "''") <> "'"

  test "note_exists?/3 (note_by_path_query) reads notes_path_live", %{user: u, vault: v} do
    plan = plan_of(fn -> assert Notes.note_exists?(u, v, "A.md") end, ~r/"path_id" = \$/)
    assert plan =~ "notes_path_live", plan
  end

  test "get_note/3 (the full read with the body join) reads notes_path_live", ctx do
    %{user: u, vault: v} = ctx
    plan = plan_of(fn -> assert {:ok, _} = Notes.get_note(u, v, "A.md") end, ~r/"path_id" = \$/)
    assert plan =~ "notes_path_live", plan
  end

  test "note_ids_for_paths/3 reads notes_path_live", %{user: u, vault: v} do
    plan = plan_of(fn -> Notes.note_ids_for_paths(u, v, ["A.md"]) end, ~r/"path_id" = ANY/)
    assert plan =~ "notes_path_live", plan
  end

  test "a folder listing reads notes_folder", %{user: u, vault: v} do
    plan =
      plan_of(fn -> {:ok, [_]} = Notes.list_notes_in_folder(u, v, "F") end, ~r/"folder_id" = \$/)

    assert plan =~ "notes_folder", plan
  end

  test "wikilink resolution reads notes_basename", %{user: u, vault: v} do
    plan =
      plan_of(fn -> Links.resolve_target(u, v, "one", "wikilink") end, ~r/"basename_id" = ANY/)

    assert plan =~ "notes_basename", plan
  end

  # A vault created after the last ANALYZE (a first sync) has no entry in the
  # most-common-values list, so even its custom plan estimates it at ~1 row,
  # and any vault-led index ties with the path index at one page (prod E1a: a
  # non-MCV vault's custom plan walked `notes_recent_index`). No index shape
  # breaks that tie; statistics do. 20261102120000 analyzes `notes` every 2%
  # + 1,000 changed rows and keeps 1,000 vaults in the list, so a new vault
  # is walked for at most a few thousand writes. The settings asserts are
  # what guard that change. The plan half only shows the remedy (an analyzed
  # vault reads the path index); it passes on default statistics too, since
  # this DB has fewer than 100 vaults and any of them fits the list.
  test "notes keeps 1,000-entry stats and fast analyze; an analyzed new vault reads notes_path_live",
       %{user: u} do
    %{rows: [[target, user_target]]} =
      Repo.query!("""
      SELECT max(attstattarget) FILTER (WHERE attname = 'vault_id'),
             max(attstattarget) FILTER (WHERE attname = 'user_id')
      FROM pg_attribute WHERE attrelid = 'notes'::regclass
      """)

    assert {target, user_target} == {1000, 1000}

    %{rows: [[opts]]} =
      Repo.query!("SELECT reloptions FROM pg_class WHERE oid = 'notes'::regclass")

    assert "autovacuum_analyze_scale_factor=0.02" in opts
    assert "autovacuum_analyze_threshold=1000" in opts

    {:ok, fresh, _} = Engram.Vaults.register_vault(u, "Fresh", Ecto.UUID.generate())
    {:ok, _} = Notes.upsert_note(u, fresh, %{"path" => "A.md", "content" => "x"}, actor: "api")

    for _ <- 1..1000 do
      insert(:note,
        user: u,
        vault: fresh,
        path_hmac: :crypto.strong_rand_bytes(32),
        folder_hmac: :crypto.strong_rand_bytes(32),
        basename_hmac: :crypto.strong_rand_bytes(32)
      )
    end

    Repo.query!("ANALYZE notes")
    plan = plan_of(fn -> assert Notes.note_exists?(u, fresh, "A.md") end, ~r/"path_id" = \$/)
    assert plan =~ "notes_path_live", plan
  end

  test "a whole-vault read stays a named (cached) statement" do
    # Only key lookups pay for a plan per call.
    refute Notes.Keys.lookup?(
             Ecto.Query.from(n in Notes.Note, where: n.vault_id == ^Ecto.UUID.generate())
           )

    assert Notes.Keys.lookup?(
             Ecto.Query.from(n in Notes.Note, where: n.path_id == ^Ecto.UUID.generate())
           )
  end
end
