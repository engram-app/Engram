defmodule Engram.Folders.PathHashStopInertTest do
  @moduledoc """
  The path E ships: S6 step 3's write stop INERT (`Engram.Folders.PathHashStop`
  below its floor). Every folder writer must write `folders.full_path_hmac`
  exactly as release D: the hash of each row's current path.
  """
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Folders, Notes, Repo}
  alias Engram.Folders.{PathHashStop, Rows}

  setup do
    Application.put_env(:engram, :path_hash_stop_floors, :enforce)
    Application.put_env(:engram, :path_hash_stop_markers_gone, false)

    on_exit(fn ->
      Application.put_env(:engram, :path_hash_stop_floors, :assume)
      Application.put_env(:engram, :path_hash_stop_markers_gone, true)
    end)

    refute PathHashStop.floors?()

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    %{user: user, vault: vault, fk: fk}
  end

  defp tenant!(user, fun) do
    {:ok, result} = Repo.with_tenant(user.id, fun)
    result
  end

  # %{live row's current path => its stored hash}, every live row.
  defp stored(%{user: u, vault: v}) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, full_path_hmac FROM folders WHERE vault_id = $1 AND deleted_at IS NULL",
        [Ecto.UUID.dump!(v.id)]
      )

    hashes = Map.new(rows, fn [id, h] -> {Ecto.UUID.load!(id), h} end)
    paths = tenant!(u, fn -> Rows.subtree_paths(u, v.id, roots(u, v)) end)
    Map.new(paths, fn {id, path} -> {path, hashes[id]} end)
  end

  defp roots(u, v) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id FROM folders WHERE vault_id = $1 AND parent_id IS NULL AND deleted_at IS NULL",
        [Ecto.UUID.dump!(v.id)]
      )

    for [id] <- rows,
        {:ok, p} <- [tenant!(u, fn -> Rows.path_by_id(u, v.id, Ecto.UUID.load!(id)) end)],
        do: p
  end

  defp assert_d_hashes(ctx, paths) do
    got = stored(ctx)
    assert Enum.sort(Map.keys(got)) == Enum.sort(paths)
    for p <- paths, do: assert(got[p] == Rows.path_hmac(ctx.fk, p), p)
  end

  test "ensure writes every prefix's path hash", %{user: u, vault: v} = ctx do
    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["A/B/C", "A/D"]) end)
    assert_d_hashes(ctx, ["A", "A/B", "A/B/C", "A/D"])
  end

  test "the FolderTable pass fills a missing hash, as D", %{user: u, vault: v} = ctx do
    {:ok, _} = Folders.create_markers(u, v, ["A/B"])

    Repo.query!("UPDATE folders SET full_path_hmac = NULL WHERE vault_id = $1", [
      Ecto.UUID.dump!(v.id)
    ])

    Engram.DataMigrations.FolderTable.run_pass(user_ids: [u.id])
    assert_d_hashes(ctx, ["A", "A/B"])
  end

  test "a rename rewrites the whole subtree's hashes", %{user: u, vault: v} = ctx do
    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["A/B/C", "A/D", "P"]) end)
    :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "P/Z") end)
    assert_d_hashes(ctx, ["P", "P/Z", "P/Z/B", "P/Z/B/C", "P/Z/D"])
  end

  test "an S5 move rewrites the whole subtree's hashes", %{user: u, vault: v} = ctx do
    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["A/B/C", "A/D", "P"]) end)
    :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "P/Z", uncascaded: 1) end)
    assert_d_hashes(ctx, ["P", "P/Z", "P/Z/B", "P/Z/B/C", "P/Z/D"])
  end

  test "a folder delete leaves the survivors' hashes, and finds a marker by D's rule",
       %{user: u, vault: v} = ctx do
    {:ok, _} = Folders.create_markers(u, v, ["A/B", "K/L"])
    [b] = tenant!(u, fn -> Rows.ids_at(u, v.id, ["A/B"]) end)
    # B's row died under its live marker: D's rule (no live row at its hash)
    # still finds the marker.
    Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(b)])

    {:ok, %{deleted: deleted}} = Notes.delete_folder(u, v, "A")
    assert deleted >= 1

    assert %{rows: [[%NaiveDateTime{}]]} =
             Repo.query!("SELECT deleted_at FROM notes WHERE id = $1", [Ecto.UUID.dump!(b)])

    got = stored(ctx)
    for p <- ["K", "K/L"], do: assert(got[p] == Rows.path_hmac(ctx.fk, p), p)
  end
end
