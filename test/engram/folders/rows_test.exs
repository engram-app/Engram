defmodule Engram.Folders.RowsTest do
  # `Folders.Rows.ensure/4`: the one find-or-create of a folder path.
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Folders.{Folder, Rows}
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    %{user: user, vault: vault, dek: dek, fk: fk}
  end

  defp ensure!(user, vault, folder, opts \\ []) do
    {:ok, {:ok, id}} =
      Repo.with_tenant(user.id, fn -> Rows.ensure(user, vault.id, folder, opts) end)

    id
  end

  defp rows(user, vault) do
    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(f in Folder, where: f.vault_id == ^vault.id, order_by: f.inserted_at))
      end)

    rows
  end

  test "creates the whole chain, encrypted, and returns the leaf", ctx do
    %{user: u, vault: v, dek: dek, fk: fk} = ctx
    leaf = ensure!(u, v, "A/B/C")

    by_path = Map.new(rows(u, v), &{&1.full_path_hmac, &1})
    [a, b, c] = Enum.map(["A", "A/B", "A/B/C"], &Map.fetch!(by_path, Rows.path_hmac(fk, &1)))

    assert c.id == leaf
    assert [a.parent_id, b.parent_id, c.parent_id] == [nil, a.id, b.id]
    assert c.name_hmac == Rows.name_hmac(fk, "C")
    assert c.dek_version == Crypto.row_version_aad_bound()

    assert {:ok, "C"} =
             Rows.decrypt_name(dek, c.id, c.dek_version, c.name_ciphertext, c.name_nonce)

    refute c.explicit
  end

  test "is idempotent, and the root has no row", %{user: u, vault: v} do
    assert ensure!(u, v, "") == nil
    assert ensure!(u, v, "A/B") == ensure!(u, v, "A/B")
    assert length(rows(u, v)) == 2
  end

  test "creates only what is missing below an existing ancestor", %{user: u, vault: v} do
    a = ensure!(u, v, "A")
    leaf = ensure!(u, v, "A/B/C")
    assert length(rows(u, v)) == 3
    assert Enum.find(rows(u, v), &(&1.name_hmac != nil and &1.id == a))
    assert leaf != a
  end

  test "an explicit marker keeps its UUID, and marks an existing row explicit", ctx do
    %{user: u, vault: v} = ctx
    marker = Ecto.UUID.generate()
    assert ensure!(u, v, "X/Y", explicit: marker) == marker
    assert Enum.find(rows(u, v), &(&1.id == marker)).explicit

    plain = ensure!(u, v, "P")
    assert ensure!(u, v, "P", explicit: Ecto.UUID.generate()) == plain
    assert Enum.find(rows(u, v), &(&1.id == plain)).explicit
  end

  test "a marker whose row was tombstoned is revived under its own UUID", %{user: u, vault: v} do
    marker = Ecto.UUID.generate()
    ensure!(u, v, "Gone", explicit: marker)

    Repo.with_tenant(u.id, fn ->
      Repo.update_all(from(f in Folder, where: f.id == ^marker),
        set: [deleted_at: DateTime.utc_now()]
      )
    end)

    assert ensure!(u, v, "Gone", explicit: marker) == marker
    assert Enum.find(rows(u, v), &(&1.id == marker)).deleted_at == nil
    assert length(rows(u, v)) == 1
  end

  test "a row with no full_path_hmac (an older writer) is adopted, not duplicated", ctx do
    %{user: u, vault: v, fk: fk} = ctx
    id = ensure!(u, v, "Legacy")

    Repo.with_tenant(u.id, fn ->
      Repo.update_all(from(f in Folder, where: f.id == ^id), set: [full_path_hmac: nil])
    end)

    assert ensure!(u, v, "Legacy") == id
    assert Enum.find(rows(u, v), &(&1.id == id)).full_path_hmac == Rows.path_hmac(fk, "Legacy")
  end

  describe "subtree, rename, delete and restore" do
    defp by_path(user, vault, fk) do
      rows(user, vault)
      |> Enum.reject(& &1.deleted_at)
      |> Map.new(&{&1.full_path_hmac, &1})
      |> then(fn m -> fn path -> Map.get(m, Rows.path_hmac(fk, path)) end end)
    end

    defp in_tenant(user, fun) do
      {:ok, result} = Repo.with_tenant(user.id, fun)
      result
    end

    test "subtree is the folder and its descendants, not its siblings", %{user: u, vault: v} do
      ensure!(u, v, "A/B/C")
      ensure!(u, v, "A/D")
      ensure!(u, v, "Other")

      assert in_tenant(u, fn -> Rows.subtree(u, v.id, ["A/B"]) end) |> length() == 2
      assert in_tenant(u, fn -> Rows.subtree(u, v.id, ["A"]) end) |> length() == 4
      assert in_tenant(u, fn -> Rows.subtree(u, v.id, [""]) end) == []
    end

    test "rename moves one row and rewrites the descendants' path hashes", ctx do
      %{user: u, vault: v, dek: dek, fk: fk} = ctx
      leaf = ensure!(u, v, "A/B/C/D")
      ensure!(u, v, "Z")
      before_ids = rows(u, v) |> Enum.map(& &1.id) |> Enum.sort()

      assert :ok = in_tenant(u, fn -> Rows.rename(u, v.id, "A/B", "Z/Y") end)

      # No row was created or replaced: identity survives the rename.
      assert rows(u, v) |> Enum.map(& &1.id) |> Enum.sort() == before_ids

      at = by_path(u, v, fk)
      assert at.("A/B") == nil
      assert at.("A/B/C/D") == nil
      assert %{id: ^leaf} = at.("Z/Y/C/D")
      assert at.("Z/Y/C")
      y = at.("Z/Y")
      assert y.parent_id == at.("Z").id

      assert {:ok, "Y"} =
               Rows.decrypt_name(dek, y.id, y.dek_version, y.name_ciphertext, y.name_nonce)

      assert y.name_hmac == Rows.name_hmac(fk, "Y")
      # A descendant keeps its own name and parent.
      c = at.("Z/Y/C")
      assert c.parent_id == y.id
      assert c.name_hmac == Rows.name_hmac(fk, "C")
      # The old parent is untouched.
      assert at.("A")
    end

    test "a rename onto a folder that already has a row merges into it", ctx do
      %{user: u, vault: v, fk: fk} = ctx
      ensure!(u, v, "A/Same")
      moved = ensure!(u, v, "A/Only")
      keeper = ensure!(u, v, "Z/Same")
      marker = Ecto.UUID.generate()
      ensure!(u, v, "A/Same/Deep", explicit: marker)

      assert :ok = in_tenant(u, fn -> Rows.rename(u, v.id, "A", "Z") end)

      at = by_path(u, v, fk)
      assert %{id: ^keeper} = at.("Z/Same")
      assert %{id: ^moved} = at.("Z/Only")
      assert at.("Z/Same/Deep").id == marker
      assert at.("A") == nil
      # Exactly one live row per path.
      live = rows(u, v) |> Enum.reject(& &1.deleted_at)
      assert length(live) == length(Enum.uniq_by(live, & &1.full_path_hmac))
    end

    test "soft_delete stamps the subtree and restore_op brings it back", ctx do
      %{user: u, vault: v, fk: fk} = ctx
      ensure!(u, v, "A/B/C")
      ensure!(u, v, "Keep")
      op = Ecto.UUID.generate()

      assert in_tenant(u, fn -> Rows.soft_delete(u, v.id, ["A"], op) end) == 3
      at = by_path(u, v, fk)
      assert at.("A") == nil and at.("A/B/C") == nil
      assert at.("Keep")
      assert Enum.count(rows(u, v), &(&1.delete_op_id == op and &1.deleted_at)) == 3

      assert in_tenant(u, fn -> Rows.restore_op(v.id, op) end) == 3
      assert by_path(u, v, fk).("A/B/C")
      assert Enum.all?(rows(u, v), &is_nil(&1.deleted_at))
    end

    test "restore_op skips a row whose name a live sibling took", ctx do
      %{user: u, vault: v, fk: fk} = ctx
      ensure!(u, v, "A")
      op = Ecto.UUID.generate()
      in_tenant(u, fn -> Rows.soft_delete(u, v.id, ["A"], op) end)
      taken = ensure!(u, v, "A")

      assert in_tenant(u, fn -> Rows.restore_op(v.id, op) end) == 0
      assert %{id: ^taken} = by_path(u, v, fk).("A")
    end

    test "unmark_explicit clears the flag and keeps the row", ctx do
      %{user: u, vault: v, fk: fk} = ctx
      id = ensure!(u, v, "M", explicit: Ecto.UUID.generate())
      assert by_path(u, v, fk).("M").explicit

      in_tenant(u, fn -> Rows.unmark_explicit(u, v.id, "M") end)
      assert %{id: ^id, explicit: false} = by_path(u, v, fk).("M")
    end
  end

  describe "the batched resolver" do
    defp ensure_all!(user, vault, folders) do
      {:ok, {:ok, ids}} =
        Repo.with_tenant(user.id, fn -> Rows.ensure_all(user, vault.id, folders) end)

      ids
    end

    defp ensure_markers!(user, vault, markers) do
      {:ok, :ok} =
        Repo.with_tenant(user.id, fn -> Rows.ensure_markers(user, vault.id, markers) end)
    end

    test "non-normalized folder strings resolve to their leaf, \"\" to the root", %{
      user: u,
      vault: v
    } do
      leaf = ensure!(u, v, "A/B")
      assert ensure!(u, v, "A/B/") == leaf
      assert ensure!(u, v, "A//B") == leaf
      assert ensure!(u, v, "/A/B") == leaf
      assert ensure!(u, v, "") == nil
      assert ensure!(u, v, "/") == nil

      ids = ensure_all!(u, v, ["A//B", "/A/", ""])
      assert ids["A//B"] == leaf
      assert ids["/A/"] == ensure!(u, v, "A")
      assert ids[""] == nil
      assert length(rows(u, v)) == 2
    end

    test "duplicate input folders create one row each", %{user: u, vault: v} do
      ids = ensure_all!(u, v, ["X/Y", "X/Y", "X", "X/Y/Z", "X/Y"])
      assert length(rows(u, v)) == 3
      assert ids["X/Y"] != ids["X"]
      assert ids["X/Y/Z"]
    end

    test "a mixed chain: existing ancestors are kept, only the rest is created", %{
      user: u,
      vault: v
    } do
      a = ensure!(u, v, "A")
      ab = ensure!(u, v, "A/B")
      ids = ensure_all!(u, v, ["A/B/C/D", "A/E", "F/G"])

      assert length(rows(u, v)) == 2 + 2 + 1 + 2
      by_id = Map.new(rows(u, v), &{&1.id, &1})
      d = by_id[ids["A/B/C/D"]]
      c = by_id[d.parent_id]
      assert c.parent_id == ab
      assert by_id[ids["A/E"]].parent_id == a
      assert by_id[by_id[ids["F/G"]].parent_id].parent_id == nil
    end

    test "tombstoned markers are revived inside a batch, keeping their ids", %{user: u, vault: v} do
      m1 = Ecto.UUID.generate()
      m2 = Ecto.UUID.generate()
      ensure!(u, v, "Gone/One", explicit: m1)

      Repo.with_tenant(u.id, fn ->
        Repo.update_all(from(f in Folder, where: f.id == ^m1),
          set: [deleted_at: DateTime.utc_now()]
        )
      end)

      ensure_markers!(u, v, [{"Gone/One", m1}, {"Gone/Two", m2}, {"Fresh", Ecto.UUID.generate()}])

      live = rows(u, v) |> Enum.reject(& &1.deleted_at) |> Map.new(&{&1.id, &1})
      assert live[m1].explicit and live[m2].explicit
      assert length(Map.keys(live)) == 4
    end

    test "a row that loses the insert (its name is already live) falls back to a read", ctx do
      %{user: u, vault: v, fk: fk} = ctx
      # A live row for the name whose full_path_hmac is missing (an older
      # writer): the batch insert hits the live-name index, writes nothing, and
      # the fallback adopts the row instead of duplicating it.
      id = ensure!(u, v, "Legacy")

      Repo.with_tenant(u.id, fn ->
        Repo.update_all(from(f in Folder, where: f.id == ^id), set: [full_path_hmac: nil])
      end)

      ids = ensure_all!(u, v, ["Legacy/Child", "Other"])
      assert length(rows(u, v)) == 3
      assert Enum.find(rows(u, v), &(&1.id == id)).full_path_hmac == Rows.path_hmac(fk, "Legacy")
      assert Enum.find(rows(u, v), &(&1.id == ids["Legacy/Child"])).parent_id == id
    end
  end
end
