defmodule Engram.Folders.MovedFolderFeedPlanTest do
  # The moved-folder feed's leg (`Engram.Notes.moved_ids_sql/2`, O(1) folder
  # rename plan S5, Engram#2523) is a lazy Merge Append: one `ORDER BY id
  # LIMIT k` child per subfolder on `notes_folder_ref_live_id` (or
  # `notes_folder_ref_dead_id`), so a page reads about `k` entries plus one
  # descent per subfolder, never a sort of the subtree. As prod runs it:
  # `engram_app` under RLS, custom and generic plans, with prod's tenancy
  # shape (`docs/context/notes-generic-plan-mis-pick.md`).
  #
  # async: false: `QueryPlan.fresh!/1` CLUSTERs `notes`.
  use EngramWeb.ConnCase, async: false

  alias Engram.{Crypto, Folders, Notes, QueryPlan, Repo, ServiceConfig}
  alias Engram.Folders.Folder

  setup :authed_api_conn

  setup %{user: user, vault: vault} do
    {:ok, user} = Crypto.ensure_user_dek(user)
    ServiceConfig.put_override(:folder_ops, true)

    for f <- ~w(x y z), i <- 1..6 do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "A/#{f}/n#{i}.md", "content" => "a"},
          actor: "api"
        )
    end

    {:ok, %{seq: seq}} = Folders.rename(user, vault, "A", "B")
    :ok = Notes.delete_note(user, vault, "B/x/n1.md")

    for col <- ~w(user_id vault_id),
        do: Repo.query!("ALTER TABLE notes ALTER COLUMN #{col} SET (n_distinct = 40)")

    QueryPlan.fresh!("notes")
    %{user: user, vault: vault, seq: seq}
  end

  test "both legs are a Merge Append of their index, no sort, no seq scan", ctx do
    %{user: u, vault: v, seq: seq} = ctx

    refs =
      Repo.with_tenant!(u.id, fn ->
        folder = Repo.get_by!(Folder, vault_id: v.id, notes_cascaded: false)
        Folders.Rows.descendant_ids(v.id, folder.id, 100)
      end)

    raw = Enum.map(refs, &Ecto.UUID.dump!/1)
    zero = Ecto.UUID.dump!("00000000-0000-0000-0000-000000000000")
    params = [Ecto.UUID.dump!(v.id), raw, seq, zero, 3]

    for which <- [:live, :dead] do
      # The custom plan folds a padded (NULL) slot to an empty child, so it is
      # read at the subtree's own width; the generic plan, which prod reuses,
      # at the padded width `moved_ids/6` sends.
      %{custom: custom} =
        QueryPlan.rls_plans(u.id, Notes.moved_ids_sql(which, length(refs)), params)

      %{generic: generic} = QueryPlan.rls_plans(u.id, Notes.moved_ids_sql(which, 8), params)

      for plan <- [custom, generic] do
        assert plan =~ "Merge Append", plan
        assert plan =~ "notes_folder_ref_#{which}_id", plan
        refute plan =~ ~r/(^|->)\s*Sort \(/m, plan
        refute plan =~ "Seq Scan", plan
      end
    end
  end
end
