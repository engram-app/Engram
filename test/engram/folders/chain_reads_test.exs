defmodule Engram.Folders.ChainReadsTest do
  # O(1) folder rename plan, Gap A (Engram#2523): the folder readers
  # (`Rows.ids_by_path/3`, `ids_at/3`, `subtree/3`, `subtree_refs/3`, and
  # through them listings, search's folder filter, the folder-op wire and
  # every folder rename/delete) find a folder by walking its path down the
  # parent chain on `folders_live_name`, never by `full_path_hmac`. From S5
  # a rename rewrites ONE folder row, so a descendant's stored path hash goes
  # stale; this release is S5's rollback target, so it must already read the
  # chain.
  #
  # Not async: the RLS plan test alters column statistics and CLUSTERs.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, FolderRows, Folders, Notes, QueryPlan, QueryRecorder, Repo}
  alias Engram.Folders.Rows

  @paths [
    "A",
    "A/B",
    "A/B/C",
    "A/B/C/D",
    "A/B/C/D/E",
    "A/b",
    "Case",
    "case",
    "Ünïcødé/日本 語",
    "Other"
  ]

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    {:ok, _} = Folders.create_markers(user, vault, @paths)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "A/B/C/x.md", "content" => "x"}, actor: "api")

    %{user: user, vault: vault}
  end

  defp tenant(user, fun), do: Repo.with_tenant!(user.id, fun)

  defp by_path(u, v, paths), do: tenant(u, fn -> Rows.ids_by_path(u, v.id, paths) end)
  defp at(u, v, paths), do: tenant(u, fn -> Rows.ids_at(u, v.id, paths) end)
  defp sub(u, v, paths), do: tenant(u, fn -> u |> Rows.subtree(v.id, paths) |> ids() end)
  defp refs(u, v, paths), do: tenant(u, fn -> u |> Rows.subtree_refs(v.id, paths) |> ids() end)
  defp ids(rows), do: rows |> Enum.map(& &1.id) |> Enum.sort()

  # The answer the 0.86.0 readers gave: rows by their stored `full_path_hmac`.
  defp hash_oracle(user, vault, path) do
    {:ok, fk} = Crypto.dek_filter_key(user)

    %{rows: rows} =
      Repo.query!(
        "SELECT id FROM folders WHERE vault_id = $1 AND full_path_hmac = $2 AND deleted_at IS NULL",
        [Ecto.UUID.dump!(vault.id), Rows.path_hmac(fk, path)]
      )

    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  defp sql!(sql, params), do: Repo.query!(sql, params)

  describe "parity with the stored path hash while writers cascade" do
    test "every reader answers exactly what full_path_hmac did", %{user: u, vault: v} do
      tree = FolderRows.tree(u)

      for path <- @paths do
        assert [id] = hash_oracle(u, v, path), path
        assert tree[path].id == id
        assert by_path(u, v, [path]) == %{path => id}
        assert at(u, v, [path]) == [id]

        under =
          for {p, %{id: i}} <- tree, p == path or String.starts_with?(p, path <> "/"), do: i

        assert sub(u, v, [path]) == Enum.sort(under), path
        assert refs(u, v, [path]) == Enum.sort(under), path
      end
    end

    test "case-only siblings stay two folders, each at its exact case", %{user: u, vault: v} do
      %{"Case" => upper, "case" => lower, "A/b" => b} = by_path(u, v, ["Case", "case", "A/b"])
      assert upper != lower
      assert b != by_path(u, v, ["A/B"])["A/B"]
    end

    test "the root, an unknown path and a dirty path", %{user: u, vault: v} do
      e = by_path(u, v, ["A/B/C/D/E"])["A/B/C/D/E"]
      assert by_path(u, v, ["", "Nope", "A/Nope/C"]) == %{"" => nil, "Nope" => nil, "A/Nope/C" => nil}
      assert by_path(u, v, ["A//B/C/D/E/"]) == %{"A//B/C/D/E/" => e}
      assert at(u, v, [""]) == []
      assert sub(u, v, [""]) == []
      assert by_path(u, v, []) == %{}
    end

    test "list_folder still lists the folder's notes", %{user: u, vault: v} do
      assert {:ok, %{notes: [%{path: "A/B/C/x.md"}]}} =
               Notes.list_notes_in_folder_page(u, v, "A/B/C", limit: 10)
    end
  end

  describe "a folder renamed without a cascade (S5 write shape)" do
    setup %{user: u, vault: v} do
      b = by_path(u, v, ["A/B"])["A/B"]
      FolderRows.move_uncascaded!(u, b, "Z")
      %{b: b}
    end

    test "readers follow the chain, not the descendants' stale hashes", %{user: u, vault: v, b: b} do
      tree = FolderRows.tree(u)
      %{"A/Z/C" => %{id: c}, "A/Z/C/D" => %{id: d}, "A/Z/C/D/E" => %{id: e}} = tree

      # The stale hash still names the old path: the old readers' answer.
      assert hash_oracle(u, v, "A/B/C") == [c]
      assert hash_oracle(u, v, "A/Z/C") == []

      assert by_path(u, v, ["A/Z/C", "A/B/C", "A/Z"]) ==
               %{"A/Z/C" => c, "A/B/C" => nil, "A/Z" => b}

      assert at(u, v, ["A/Z/C/D"]) == [d]
      assert at(u, v, ["A/B/C/D"]) == []
      assert sub(u, v, ["A/Z"]) == Enum.sort([b, c, d, e])
      assert refs(u, v, ["A/Z/C"]) == Enum.sort([c, d, e])
      assert sub(u, v, ["A/B"]) == []
      assert refs(u, v, ["A/B/C"]) == []
    end
  end

  describe "rows other writers left behind" do
    test "a row with no full_path_hmac (an older writer) is found by its chain", %{
      user: u,
      vault: v
    } do
      d = by_path(u, v, ["A/B/C/D"])["A/B/C/D"]
      sql!("UPDATE folders SET full_path_hmac = NULL WHERE id = $1", [Ecto.UUID.dump!(d)])

      assert by_path(u, v, ["A/B/C/D"]) == %{"A/B/C/D" => d}
      assert at(u, v, ["A/B/C/D"]) == [d]
      assert d in sub(u, v, ["A/B/C/D"])
    end

    test "a live row under a dead ancestor has no path", %{user: u, vault: v} do
      %{"A/B" => b, "A/B/C" => c} = by_path(u, v, ["A/B", "A/B/C"])
      sql!("UPDATE folders SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(b)])

      # The old hash read still found it; the tree (`Rows.decrypt_tree/2`)
      # never showed it, and now no reader does.
      assert hash_oracle(u, v, "A/B/C") == [c]
      assert by_path(u, v, ["A/B/C"]) == %{"A/B/C" => nil}
      assert sub(u, v, ["A/B/C"]) == []
    end
  end

  describe "cost" do
    test "any number of paths is ONE statement on folders", %{user: u, vault: v} do
      paths = Enum.flat_map(@paths, &[&1, &1 <> "/missing"])

      {got, queries} = QueryRecorder.record(fn -> by_path(u, v, paths) end)
      me = self()

      assert map_size(got) == length(paths)
      assert [walk] = for(%{sql: s, pid: ^me} <- queries, s =~ ~r/\bfolders\b/, do: s)
      assert walk =~ "WITH RECURSIVE q"
      refute walk =~ "full_path_hmac"
    end

    test "the walk is sent unnamed, so a generic plan never replaces the tenant's estimate",
         %{user: u, vault: v} do
      Repo.query!("DISCARD PLANS")
      {_, queries} = QueryRecorder.record(fn -> for _ <- 1..7, do: by_path(u, v, ["A/B/C"]) end)
      me = self()
      walks = for %{sql: s, pid: ^me} <- queries, s =~ "WITH RECURSIVE q", uniq: true, do: s

      assert [_] = walks

      assert %{rows: []} =
               Repo.query!(
                 "SELECT name FROM pg_prepared_statements WHERE statement = ANY($1)",
                 [walks]
               )
    end

    test "as engram_app under RLS: one folders_live_name probe per prefix",
         %{user: u, vault: v} do
      # Siblings at every level, so a probe by parent alone reads many rows.
      {:ok, _} =
        Folders.create_markers(
          u,
          v,
          for(i <- 1..80, do: "R#{i}") ++ for(i <- 1..80, do: "A/B/S#{i}")
        )

      Repo.query!("ALTER TABLE folders ALTER COLUMN vault_id SET (n_distinct = 40)")
      Repo.query!("ALTER TABLE folders ALTER COLUMN user_id SET (n_distinct = 40)")
      QueryPlan.fresh!("folders")

      paths = ["A/B/C/D/E", "A/B/C/x", "Other", "Ünïcødé/日本 語"]

      {_, queries} = QueryRecorder.record(fn -> by_path(u, v, paths) end)
      me = self()
      [{sql, params}] = for %{sql: s, params: p, pid: ^me} <- queries, s =~ "folders", do: {s, p}

      # The custom plan is the only one that runs (unnamed, above). Under
      # these statistics (40 tenants, so about 4 folders each by the
      # average) a probe keyed only by the policy's tenant InitPlan ties
      # with a `folders_user` scan; the bound `user_id` lets the planner
      # see this tenant's real count.
      plan = QueryPlan.rls_plans(u.id, sql, params).custom

      # 9 distinct prefixes: A, A/B, A/B/C, A/B/C/D, A/B/C/D/E, A/B/C/x,
      # Other, Ünïcødé, Ünïcødé/日本 語.
      assert plan =~ "folders_live_name", plan
      refute plan =~ "Seq Scan on folders", plan
      refute plan =~ "folders_full_path", plan
      refute plan =~ "folders_parent", plan
      refute plan =~ "folders_user", plan
      # 2-3 index pages per probe; a scan of the tenant's 170 folders is more.
      assert QueryPlan.buffers(plan) <= 9 * 3, plan
    end
  end
end
