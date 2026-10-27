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
end
