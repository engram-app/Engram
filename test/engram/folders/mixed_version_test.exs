defmodule Engram.Folders.MixedVersionTest do
  @moduledoc """
  S6 step 3's read switch (Engram#2523) during a mixed-version window: 0.89.0
  nodes find folders by `folders.full_path_hmac` (`Engram.Folders.RowsV089`,
  that release's code verbatim) while D nodes walk the parent chain
  (`Engram.Folders.Rows`). Both write the hash. Each test interleaves the
  two on one vault and asserts what both need: one live row per path, D
  resolves it, and no two live rows carry the same path hash (0.89.0 keys a
  map by it, so a duplicate makes its lookup pick a row at random).
  """
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Folders.{PathHmacs, Rows, RowsV089}
  alias Engram.Repo

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    %{user: user, vault: vault, fk: fk}
  end

  defp tenant!(user, fun) do
    {:ok, result} = Repo.with_tenant(user.id, fun)
    result
  end

  defp d_ids(u, v, paths), do: tenant!(u, fn -> Rows.ids_by_path(u, v.id, paths) end)

  defp d_path(u, v, id) do
    {:ok, path} = tenant!(u, fn -> Rows.path_by_id(u, v.id, id) end)
    path
  end

  # Every live row of the vault, as its chain path (D's view), and no live
  # path hash held twice (0.89.0's view).
  defp assert_consistent!(%{user: u, vault: v}) do
    %{rows: dups} =
      Repo.query!(
        """
        SELECT full_path_hmac, count(*) FROM folders
        WHERE vault_id = $1 AND deleted_at IS NULL AND full_path_hmac IS NOT NULL
        GROUP BY 1 HAVING count(*) > 1
        """,
        [Ecto.UUID.dump!(v.id)]
      )

    assert dups == [], "live rows share a full_path_hmac: #{length(dups)}"

    tree = Engram.FolderRows.tree(u)
    paths = Map.keys(tree)
    assert length(paths) == length(Enum.uniq(paths))
    tree
  end

  defp row_hash(id) do
    %{rows: [[h]]} =
      Repo.query!("SELECT full_path_hmac FROM folders WHERE id = $1", [Ecto.UUID.dump!(id)])

    h
  end

  defp stale!(fk, id, path) do
    Repo.query!("UPDATE folders SET full_path_hmac = $1 WHERE id = $2", [
      Rows.path_hmac(fk, path),
      Ecto.UUID.dump!(id)
    ])
  end

  describe "interleaved ensures at one path" do
    test "0.89.0 then D, and D then 0.89.0: one row each", %{user: u, vault: v} = ctx do
      {:ok, a} = tenant!(u, fn -> RowsV089.ensure(u, v.id, "A/B") end)
      assert {:ok, ^a} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)

      {:ok, x} = tenant!(u, fn -> Rows.ensure(u, v.id, "X/Y") end)
      assert {:ok, ^x} = tenant!(u, fn -> RowsV089.ensure(u, v.id, "X/Y") end)

      assert %{"A/B" => %{id: ^a}, "X/Y" => %{id: ^x}} = assert_consistent!(ctx)
    end

    test "a row with no hash (a backfill gap): both find it, 0.89.0 repairs it",
         %{user: u, vault: v} = ctx do
      {:ok, b} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)

      Repo.query!("UPDATE folders SET full_path_hmac = NULL WHERE vault_id = $1", [
        Ecto.UUID.dump!(v.id)
      ])

      assert {:ok, ^b} = tenant!(u, fn -> RowsV089.ensure(u, v.id, "A/B") end)
      assert {:ok, ^b} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      assert_consistent!(ctx)
    end

    # A moved folder whose descendant kept its OLD path's hash (a name that
    # would not decrypt drops it from the rename's rewrite): D creates the
    # old path anew by chain, and its hash must not then be held twice.
    test "D ensure at a path a stale hash still names", %{user: u, vault: v, fk: fk} = ctx do
      {:ok, b} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "C") end)
      stale!(fk, b, "A/B")

      {:ok, new} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      refute new == b
      assert d_path(u, v, b) == "C/B"
      assert d_path(u, v, new) == "A/B"
      assert_consistent!(ctx)

      # 0.89.0 then resolves the path to D's row, not the moved one.
      assert {:ok, ^new} = tenant!(u, fn -> RowsV089.ensure(u, v.id, "A/B") end)
      assert_consistent!(ctx)
    end

    test "0.89.0 ensure at a path a stale hash names, then D",
         %{user: u, vault: v, fk: fk} = ctx do
      {:ok, b} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "C") end)
      stale!(fk, b, "A/B")

      # 0.89.0's own answer (its hash lookup): the moved row. Not ours to fix.
      _ = tenant!(u, fn -> RowsV089.ensure(u, v.id, "A/B") end)

      {:ok, new} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      assert d_path(u, v, new) == "A/B"
      assert d_path(u, v, b) == "C/B"
      assert_consistent!(ctx)
    end
  end

  describe "every hash writer keeps one live row per hash" do
    # A restore revives a row with the hash it died with. Red before: the
    # revived row and the live row D made at that path shared it.
    test "a restore yields a stale hash to the live holder", %{user: u, vault: v, fk: fk} = ctx do
      {:ok, b} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "C") end)
      stale!(fk, b, "A/B")
      op = Ecto.UUID.generate()
      assert tenant!(u, fn -> Rows.soft_delete(u, v.id, ["C"], op) end) >= 1

      {:ok, n} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      _ = tenant!(u, fn -> Rows.restore_op(u, v.id, op) end)

      assert d_path(u, v, b) == "C/B"
      assert d_path(u, v, n) == "A/B"
      assert_consistent!(ctx)
    end

    # Review probe 1: a put aimed at a DEAD row (a DEK rotation re-keys dead
    # rows, in chunks) must not cost the live row at that path its hash. Red
    # on ccbb518a1: the live row was left with none.
    test "a put on a dead row keeps the live row's hash", %{user: u, vault: v, fk: fk} = ctx do
      {:ok, dead} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      assert tenant!(u, fn -> Rows.soft_delete(u, v.id, ["A"], Ecto.UUID.generate()) end) >= 1
      {:ok, live} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)

      _ = tenant!(u, fn -> PathHmacs.put(u.id, [{dead, Rows.path_hmac(fk, "A/B")}]) end)

      assert row_hash(live) == Rows.path_hmac(fk, "A/B")
      assert_consistent!(ctx)
    end

    # Review probe 2: a restored row back at its path takes that path's hash
    # from a stale live holder, so 0.89.0 resolves the path to it. Red on
    # ccbb518a1: it yielded its correct hash to the stale row.
    test "a restored row takes its current path's hash from a stale holder",
         %{user: u, vault: v, fk: fk} = ctx do
      {:ok, r} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      op = Ecto.UUID.generate()
      assert tenant!(u, fn -> Rows.soft_delete(u, v.id, ["A"], op) end) >= 1
      {:ok, s} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "C") end)
      stale!(fk, s, "A/B")

      _ = tenant!(u, fn -> Rows.restore_op(u, v.id, op) end)

      assert d_path(u, v, r) == "A/B"
      assert d_path(u, v, s) == "C/B"
      assert row_hash(r) == Rows.path_hmac(fk, "A/B")
      assert {:ok, ^r} = tenant!(u, fn -> RowsV089.ensure(u, v.id, "A/B") end)
      assert_consistent!(ctx)
    end

    # The FolderTable heal stamps a row's path hash. Red before: it did not
    # release it from a stale holder.
    test "the FolderTable heal releases the hash it stamps", %{user: u, vault: v, fk: fk} = ctx do
      {:ok, _} = Engram.Folders.create_markers(u, v, ["A/B"])
      {:ok, y} = tenant!(u, fn -> Rows.ensure(u, v.id, "Y") end)
      [b] = tenant!(u, fn -> Rows.ids_at(u, v.id, ["A/B"]) end)

      Repo.query!("UPDATE folders SET full_path_hmac = NULL WHERE id = $1", [Ecto.UUID.dump!(b)])
      stale!(fk, y, "A/B")

      Engram.DataMigrations.FolderTable.run_pass(user_ids: [u.id])

      %{rows: [[h]]} =
        Repo.query!("SELECT full_path_hmac FROM folders WHERE id = $1", [Ecto.UUID.dump!(b)])

      assert h == Rows.path_hmac(fk, "A/B")
      assert_consistent!(ctx)
    end
  end

  # One per read switch: written by 0.89.0, read by D.
  describe "0.89.0 writes, D reads" do
    test "create", %{user: u, vault: v} = ctx do
      {:ok, ids} = tenant!(u, fn -> RowsV089.ensure_all(u, v.id, ["A/B/C", "A/D"]) end)

      for {path, id} <- ids do
        assert d_ids(u, v, [path])[path] == id
        assert d_path(u, v, id) == path
        assert {:ok, ^id} = tenant!(u, fn -> Rows.ensure(u, v.id, path) end)
      end

      assert_consistent!(ctx)
    end

    test "rename", %{user: u, vault: v} = ctx do
      {:ok, b} = tenant!(u, fn -> RowsV089.ensure(u, v.id, "A/B") end)
      :ok = tenant!(u, fn -> RowsV089.rename(u, v.id, "A", "Z") end)

      assert %{"A" => nil, "Z/B" => ^b} = d_ids(u, v, ["A", "Z/B"])
      assert {:ok, ^b} = tenant!(u, fn -> Rows.ensure(u, v.id, "Z/B") end)
      assert_consistent!(ctx)
    end

    test "move", %{user: u, vault: v} = ctx do
      {:ok, _} = tenant!(u, fn -> RowsV089.ensure_all(u, v.id, ["A/B", "P"]) end)
      [b] = tenant!(u, fn -> Rows.ids_at(u, v.id, ["A/B"]) end)
      :ok = tenant!(u, fn -> RowsV089.rename(u, v.id, "A", "P/A") end)

      assert d_path(u, v, b) == "P/A/B"
      # D's cycle check walks the chain 0.89.0 wrote.
      assert {:error, :invalid_path} =
               tenant!(u, fn -> {:ok, Rows.check_move(u, v.id, "P", "P/A/B/x")} end)
               |> then(fn {:ok, r} -> r end)

      assert_consistent!(ctx)
    end

    test "delete", %{user: u, vault: v} = ctx do
      {:ok, b} = tenant!(u, fn -> RowsV089.ensure(u, v.id, "A/B") end)
      n = tenant!(u, fn -> RowsV089.soft_delete(u, v.id, ["A"], Ecto.UUID.generate()) end)
      assert n >= 1

      assert %{"A" => nil, "A/B" => nil} = d_ids(u, v, ["A", "A/B"])
      {:ok, new} = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)
      refute new == b
      assert_consistent!(ctx)
    end
  end
end
