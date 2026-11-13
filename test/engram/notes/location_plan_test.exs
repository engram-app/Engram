defmodule Engram.Notes.LocationPlanTest do
  # Cost guard for the S3 by-path lookup (`Engram.Notes.Location`): one
  # statement, the live path index, and in a vault with a folder moved
  # without a cascade an index probe per path segment on `folders_live_name`
  # then `notes_name_key_live` for the name. Never a scan of the vault's
  # notes or of a folder's notes, whatever their count. Plans are read as
  # prod runs them, as `engram_app` with the tenant set
  # (`QueryPlan.rls_plans/3`): as the suite's superuser RLS is skipped, and
  # a qual it would keep from an index looks fine
  # (docs/context/rls-leakproof-index-quals.md).
  use Engram.DataCase, async: false

  alias Engram.{Crypto, DataMigrations, Notes}
  alias Engram.QueryPlan
  alias Engram.QueryRecorder
  alias Engram.Repo

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    for i <- 1..40,
        do:
          {:ok, _} =
            Notes.upsert_note(user, vault, %{"path" => "A/B/n#{i}.md", "content" => "n"},
              actor: "api"
            )

    for _ <- 1..300, do: insert(:note, user: user, vault: vault)

    # Siblings at every level, so a probe by parent alone reads many rows
    # and the planner weighs the name.
    {:ok, _} =
      Engram.Folders.create_markers(
        user,
        vault,
        for(i <- 1..60, do: "R#{i}") ++ for(i <- 1..60, do: "A/S#{i}")
      )

    # Statistics from these rows, as prod's are current.
    Repo.query!("ANALYZE notes")
    Repo.query!("ANALYZE folders")

    on_exit(fn -> Engram.Cache.clear_local(:note_split) end)
    %{user: user, vault: vault}
  end

  defp mark_moved!(user, vault) do
    {:ok, _} = Engram.Folders.create_markers(user, vault, ["Moved"])

    Repo.query!("UPDATE folders SET notes_cascaded = false WHERE vault_id = $1", [
      Ecto.UUID.dump!(vault.id)
    ])
  end

  # The custom plan, under RLS, of the lookup `note_exists?/3` sends for
  # `path` (unheld, so in a moved vault the walk and the name probe run).
  defp lookup_plan(user, vault, path, exists?) do
    {_, queries} =
      QueryRecorder.record(fn -> assert Notes.note_exists?(user, vault, path) == exists? end)

    me = self()

    [%{sql: sql, params: params}] =
      for %{sql: sql, pid: ^me} = q <- queries,
          sql =~ "WITH RECURSIVE",
          sql =~ ~s(FROM "notes"),
          do: q

    QueryPlan.rls_plans(user.id, sql, params).custom
  end

  defp assert_plan(user, vault, path_index) do
    mark_moved!(user, vault)
    plan = lookup_plan(user, vault, "A/B/new.md", false)

    for index <- ["folders_moved_live", "folders_live_name", "notes_name_key_live", path_index],
        do: assert(plan =~ index, "expected #{index} in:\n#{plan}")

    # No level reads a whole vault's (or a parent's) folders.
    refute plan =~ "Seq Scan", plan
    refute plan =~ "Hash Join", plan
    refute plan =~ "folders_parent", plan
    refute plan =~ "notes_user_vault_live", plan
  end

  # Prod: the `note_split` ledger is done, so the path key is `path_id` on
  # `notes_path_live`.
  test "a by-path lookup reads the folder, name and live path-id indexes", ctx do
    :ok = DataMigrations.mark_done("note_split", 1)
    Engram.Cache.clear_local(:note_split)
    assert Engram.Notes.Keys.ids?()
    assert_plan(ctx.user, ctx.vault, "notes_path_live")
  end

  test "before the note_split ledger: the path_hmac index", ctx do
    Engram.Cache.clear_local(:note_split)
    refute Engram.Notes.Keys.ids?()
    assert_plan(ctx.user, ctx.vault, "notes_user_vault_path_v2")
  end

  # The walk sits behind the moved-folder probe (`WalkSql.name_match_by_id/0`):
  # an unmoved vault never runs it. Run for real on the statement the app
  # sends, not inferred from the plan's shape.
  defp walk_line(plan) do
    plan |> String.split("\n") |> Enum.find(&(&1 =~ "Recursive Union")) || flunk(plan)
  end

  test "an unmoved vault never runs the folder walk; a moved one does", ctx do
    assert walk_line(lookup_plan(ctx.user, ctx.vault, "A/B/new.md", false)) =~ "never executed"
    mark_moved!(ctx.user, ctx.vault)
    refute walk_line(lookup_plan(ctx.user, ctx.vault, "A/B/new.md", false)) =~ "never executed"
  end
end
