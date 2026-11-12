defmodule Engram.Notes.LocationPlanTest do
  # Cost guard for the S3 by-path lookup (`Engram.Notes.Location`): one
  # statement, an index probe per path segment on `folders_live_name`, then
  # `notes_folder_name_live` for the name and the live path index for the
  # fallback arm. Never a scan of the vault's notes or of a folder's notes,
  # whatever their count.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, DataMigrations, Notes}
  alias Engram.QueryPlan
  alias Engram.QueryRecorder

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

    :ok = DataMigrations.mark_done("note_name", 1)
    Engram.Cache.clear_local(:note_name)
    on_exit(fn -> Engram.Cache.clear_local(:note_name) end)
    %{user: user, vault: vault}
  end

  test "a by-path lookup reads the folder and name indexes", %{user: u, vault: v} do
    {_, queries} = QueryRecorder.record(fn -> assert Notes.note_exists?(u, v, "A/B/n7.md") end)

    [sql] =
      for sql <- QueryPlan.reading(queries, "notes"), sql =~ "WITH RECURSIVE", do: sql

    plan = QueryPlan.generic_plan(sql, analyze: ["notes", "folders"])

    for index <- ~w(folders_live_name notes_folder_name_live notes_user_vault_path_v2),
        do: assert(plan =~ index, "expected #{index} in:\n#{sql}\n\nplan:\n#{plan}")

    # No level reads a whole vault's (or a parent's) folders.
    refute plan =~ "Seq Scan", plan
    refute plan =~ "Hash Join", plan
    refute plan =~ "folders_parent", plan
  end
end
