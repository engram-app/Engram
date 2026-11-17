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

  import Ecto.Query

  setup :authed_api_conn

  setup %{user: user, vault: vault} do
    {:ok, user} = Crypto.ensure_user_dek(user)
    ServiceConfig.put_override(:folder_ops, true)

    for f <- ~w(x y), i <- 1..4 do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "A/#{f}/n#{i}.md", "content" => "a"},
          actor: "api"
        )
    end

    {:ok, %{seq: seq}} = Folders.rename(user, vault, "A", "B")
    :ok = Notes.delete_note(user, vault, "B/x/n1.md")

    # Prod-sized folders, without a write through the app per row: each
    # subfolder gets 1,500 live copies of one of its notes (fresh path hash,
    # written before the move) and 1,500 dead ones (died after the move). A
    # handful of rows sort for free, which proves nothing about the bound.
    # X3: 1,000 tombstones that died BEFORE the move in one subfolder, with
    # ids below every row the leg serves there (cloned first; ids are
    # UUIDv7), so the dead leg walks past them: its `seq > move` rejects
    # them from the index tuple.
    {:ok, old} = Notes.get_note(user, vault, "B/y/n3.md")
    clone!(old.id, 1_000, %{"deleted_at" => "2026-11-01T00:00:00Z", "seq" => 1})

    for f <- ~w(x y) do
      {:ok, note} = Notes.get_note(user, vault, "B/#{f}/n2.md")
      clone!(note.id, 1_500, %{})
      clone!(note.id, 1_500, %{"deleted_at" => "2026-11-17T00:00:00Z", "seq" => seq + 1})
    end

    # Prod-sized folder table for the walk plans: a tenant's folders are
    # many, so a walk keyed only by the tenant would read them all a level.
    {:ok, _} =
      Repo.with_tenant!(user.id, fn ->
        Folders.Rows.ensure_all(user, vault.id, for(i <- 1..300, do: "Z/f#{i}"))
      end)

    # A deleted moved folder, for the dead-row walk and the seq range.
    for i <- 1..3 do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "G/s/g#{i}.md", "content" => "g"},
          actor: "api"
        )
    end

    {:ok, _} = Folders.rename(user, vault, "G", "G2")
    {:ok, _} = Folders.delete(user, vault, "G2", recursive: true)

    for col <- ~w(user_id vault_id),
        do: Repo.query!("ALTER TABLE notes ALTER COLUMN #{col} SET (n_distinct = 40)")

    # And prod's folder count (about 47k folder rows, 2026-11-16): a test
    # vault's two or three folders make `folder_ref_id = $n` look like a third
    # of the table, which no prod plan sees.
    Repo.query!("ALTER TABLE notes ALTER COLUMN folder_ref_id SET (n_distinct = 5000)")

    QueryPlan.fresh!("notes")
    %{user: user, vault: vault, seq: seq}
  end

  defp clone!(id, n, set) do
    Repo.query!(
      """
      INSERT INTO notes
      SELECT (jsonb_populate_record(r, jsonb_build_object('id', uuidv7(),
               'path_hmac', '\\x' || encode(sha256(convert_to(g::text || r.id::text, 'UTF8')), 'hex'))
               || $3::jsonb)).*
      FROM notes r, generate_series(1, $2) g
      WHERE r.id = $1
      """,
      [Ecto.UUID.dump!(id), n, set]
    )
  end

  # `fun`'s one recorded statement matching `pattern`, planned as prod runs it.
  defp plans(user, fun, pattern) do
    {_, queries} = Engram.QueryRecorder.record(fn -> Repo.with_tenant!(user.id, fun) end)
    me = self()
    [{sql, params}] = for %{sql: s, params: p, pid: ^me} <- queries, s =~ pattern, do: {s, p}
    QueryPlan.rls_plans(user.id, sql, params)
  end

  defp folders_fresh! do
    for col <- ~w(user_id vault_id),
        do: Repo.query!("ALTER TABLE folders ALTER COLUMN #{col} SET (n_distinct = 40)")

    QueryPlan.fresh!("folders")
  end

  test "X3: the dead leg is index-only; old tombstones are rejected on the index", ctx do
    %{user: u, vault: v, seq: seq} = ctx
    QueryPlan.all_visible!(["notes"])

    refs =
      Repo.with_tenant!(u.id, fn ->
        folder = Repo.get_by!(Folder, vault_id: v.id, seq: seq)
        Folders.Rows.descendant_ids(v.id, folder.id, 100)
      end)

    zero = Ecto.UUID.dump!("00000000-0000-0000-0000-000000000000")
    params = [Ecto.UUID.dump!(v.id), Enum.map(refs, &Ecto.UUID.dump!/1), seq, zero, 3]

    %{custom: custom} =
      QueryPlan.rls_plans(u.id, Notes.moved_ids_sql(:dead, length(refs)), params)

    %{generic: generic} = QueryPlan.rls_plans(u.id, Notes.moved_ids_sql(:dead, 8), params)

    for plan <- [custom, generic] do
      # Index-only: `seq` and `user_id` are INCLUDEd, so the tenant qual and
      # the `seq > move` filter read the index tuple, never the row. The
      # rejected tombstones still cost a heap fetch each HERE because a test
      # sandbox cannot VACUUM (no page is all-visible); in prod, with the
      # visibility map set, they cost index entries only. Not provable in a
      # sandbox: the plan shape is what is pinned.
      assert plan =~ "Index Only Scan using notes_folder_ref_dead_id", plan
      assert plan =~ ~r/Rows Removed by Filter: (9\d\d|1\d\d\d)/, plan
      refute plan =~ "Bitmap Heap Scan", plan
      refute plan =~ ~r/(^|->)\s*Sort \(/m, plan
    end
  end

  test "X2: moved folders by seq, dead ones included, read folders_moved_seq", ctx do
    %{user: u, vault: v} = ctx
    folders_fresh!()

    %{custom: custom, generic: generic} =
      plans(u, fn -> Folders.Rows.moved_since(v.id, 0, false, dead: true) end, "notes_cascaded")

    for plan <- [custom, generic] do
      assert plan =~ "folders_moved_seq", plan
      refute plan =~ "Seq Scan", plan
    end
  end

  test "X2: the dead-row subtree walk is index reads, no seq scan", ctx do
    %{user: u, vault: v} = ctx
    folders_fresh!()

    dead =
      Repo.with_tenant!(u.id, fn ->
        Repo.one!(
          from(f in Folder,
            where: f.vault_id == ^v.id and not is_nil(f.deleted_at) and not f.notes_cascaded,
            select: f.id
          )
        )
      end)

    %{custom: custom, generic: generic} =
      plans(
        u,
        fn -> Folders.Rows.descendant_ids(v.id, dead, 100, dead: true) end,
        "folder_subtree"
      )

    for plan <- [custom, generic] do
      # Each level probes the parent's children (`folders_parent`), never
      # the tenant's whole folder list.
      assert plan =~ "folders_parent", plan
      refute plan =~ "folders_user", plan
      refute plan =~ "Seq Scan", plan
    end
  end

  test "both legs are a Merge Append of their index, no sort, no seq scan", ctx do
    %{user: u, vault: v, seq: seq} = ctx

    refs =
      Repo.with_tenant!(u.id, fn ->
        folder = Repo.get_by!(Folder, vault_id: v.id, seq: seq)
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
