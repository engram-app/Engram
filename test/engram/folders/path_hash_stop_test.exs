defmodule Engram.Folders.PathHashStopTest do
  @moduledoc """
  S6 step 3 phase 2 (Engram#2523): the `folders.full_path_hmac` write stop.
  Release D still reads the hash, so the stop waits for the rollback floor to
  reach D (`Engram.Folders.PathHashStop`). Until then it is inert and every
  writer keeps the hash exactly as D does. The test env assumes the stop on
  (`config/test.exs`); the inert tests switch back to the enforced floor.
  """
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Folders, Notes, QueryRecorder, Repo}
  alias Engram.Folders.{PathHashStop, Rows}
  alias Engram.Release.Floor

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

  defp inert! do
    Application.put_env(:engram, :path_hash_stop_floors, :enforce)
    Application.put_env(:engram, :path_hash_stop_markers_gone, false)

    on_exit(fn ->
      Application.put_env(:engram, :path_hash_stop_floors, :assume)
      Application.put_env(:engram, :path_hash_stop_markers_gone, true)
    end)
  end

  defp hashes(vault) do
    %{rows: rows} =
      Repo.query!("SELECT id, full_path_hmac FROM folders WHERE vault_id = $1", [
        Ecto.UUID.dump!(vault.id)
      ])

    Map.new(rows, fn [id, h] -> {Ecto.UUID.load!(id), h} end)
  end

  # The floor-raise (#2674) put the rollback floor at release D: the floor
  # leg holds on the real floor, so the vault's markers alone decide.
  test "the floor reaches release D: the stop waits only on the markers", %{user: u, vault: v} do
    assert PathHashStop.reads_release() == "release-v0.90.0"
    assert Floor.at_least?(PathHashStop.reads_release())
    assert PathHashStop.floors?(:enforce)
    assert PathHashStop.on?(u.id, v.id, :enforce)

    Application.put_env(:engram, :path_hash_stop_markers_gone, false)
    on_exit(fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, true) end)
    refute PathHashStop.on?(u.id, v.id, :enforce)
  end

  test "an absent or not-done ledger reads as markers present", %{user: u, vault: v} do
    refute PathHashStop.marker_delete_done?(Engram.NoSuchLedger, u.id, v.id)
    refute PathHashStop.marker_delete_done?(__MODULE__.NotDone, u.id, v.id)
    assert PathHashStop.marker_delete_done?(__MODULE__.Done, u.id, v.id)
    # Until Engram#2652 is on this branch's main, the real ledger is absent.
    real = Engram.DataMigrations.FolderMarkerDelete

    unless Code.ensure_loaded?(real),
      do: refute(PathHashStop.marker_delete_done?(real, u.id, v.id))
  end

  defmodule Done, do: def(done?(_user_id, _vault_id), do: true)
  defmodule NotDone, do: def(done?(_user_id, _vault_id), do: false)

  # Stand-in for `FolderMarkerDelete.done?/2` (Engram#2652): ledger done, and
  # no live marker in the vault right now.
  defmodule Probe do
    import Ecto.Query

    def done?(user_id, vault_id) do
      not Engram.Repo.exists?(
        from(n in Engram.Notes.Note,
          where:
            n.user_id == ^user_id and n.vault_id == ^vault_id and n.kind == "folder" and
              is_nil(n.deleted_at)
        )
      )
    end
  end

  defp probe! do
    Application.put_env(:engram, :path_hash_stop_markers_gone, __MODULE__.Probe)
    on_exit(fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, true) end)
  end

  # Per vault, never stale: a vault the step 4 delete emptied runs the stop;
  # a marker coming back (a rollback to a release that writes them) puts THAT
  # vault back on D's writes at once, and another vault is not affected.
  test "per vault: markers gone is on, a marker back (rollback) is D again", ctx do
    %{user: u, vault: v, fk: fk} = ctx
    other = insert(:vault, user: u)
    probe!()

    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["A/B"]) end)
    assert tenant!(u, fn -> PathHashStop.on?(u.id, v.id) end)
    :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "Z") end)
    assert hashes(v) |> Map.values() |> Enum.all?(&is_nil/1)

    # The rollback: a marker in `v` again.
    {:ok, _} = Folders.create_markers(u, v, ["Z/B"])
    refute tenant!(u, fn -> PathHashStop.on?(u.id, v.id) end)
    assert tenant!(u, fn -> PathHashStop.on?(u.id, other.id) end)

    assert {:ok, _} = Folders.rename(u, v, "Z", "Y")
    ids = tenant!(u, fn -> Rows.ids_by_path(u, v.id, ["Y", "Y/B"]) end)
    for {path, id} <- ids, do: assert(hashes(v)[id] == Rows.path_hmac(fk, path), path)

    # ...and the marker's folder op takes D's rule: found by its path hash.
    assert {:ok, %{deleted: 1}} = Notes.delete_folder(u, v, "Y")
  end

  test "markers present (ledger not done): D's writes", %{user: u, vault: v, fk: fk} do
    Application.put_env(:engram, :path_hash_stop_markers_gone, false)
    on_exit(fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, true) end)
    refute PathHashStop.on?(u.id, v.id, :assume)

    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["A/B"]) end)
    :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "Z") end)
    ids = tenant!(u, fn -> Rows.ids_by_path(u, v.id, ["Z", "Z/B"]) end)
    for {path, id} <- ids, do: assert(hashes(v)[id] == Rows.path_hmac(fk, path), path)
  end

  # Red on d3c496f4a: the hash was never written.
  test "inert: writers and a rename keep every path hash, as release D", ctx do
    %{user: u, vault: v, fk: fk} = ctx
    inert!()

    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["A/B/C", "A/D"]) end)
    ids = tenant!(u, fn -> Rows.ids_by_path(u, v.id, ["A", "A/B", "A/B/C", "A/D"]) end)

    for {path, id} <- ids, do: assert(hashes(v)[id] == Rows.path_hmac(fk, path), path)

    :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "Z") end)
    h = hashes(v)

    for {path, new} <- [{"A", "Z"}, {"A/B", "Z/B"}, {"A/B/C", "Z/B/C"}, {"A/D", "Z/D"}],
        do: assert(h[ids[path]] == Rows.path_hmac(fk, new), new)
  end

  test "on: writers write no path hash", %{user: u, vault: v} do
    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["A/B"]) end)
    :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "Z") end)

    assert hashes(v) |> Map.values() |> Enum.all?(&is_nil/1)
  end

  # Red on d3c496f4a: `check_move` and the rename each read the subtree.
  test "on: an S5 move reads only the moved row, never its subtree", %{user: u, vault: v} do
    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["A/B/C", "A/D", "P"]) end)

    {:ok, queries} =
      tenant!(u, fn ->
        QueryRecorder.record(fn -> Rows.rename(u, v.id, "A", "P/A", uncascaded: 1) end)
      end)

    refute Enum.any?(queries, &(&1.sql =~ "folder_subtree")), inspect(Enum.map(queries, & &1.sql))
    assert %{"P/A/B/C" => _, "P/A/D" => _} = Engram.FolderRows.tree(u)
  end

  # With the stop on there is no path hash: a marker whose own row died is
  # found by its id (the rule the stop waits on S6 step 4's marker delete for).
  # With the stop on there is no path hash to trust: a marker whose own row
  # died is found by its id. Red under D's rule: another live row still holds
  # the marker's path hash (a stale hash, from before the stop), so D's "no
  # live row at its hash" excludes it, and the subtree's chain hashes do not
  # reach a dead row.
  test "on: a folder op finds a marker whose row died, past a stale hash", ctx do
    %{user: u, vault: v, fk: fk} = ctx
    {:ok, _} = Folders.create_markers(u, v, ["A/B"])
    [b] = tenant!(u, fn -> Rows.ids_at(u, v.id, ["A/B"]) end)
    tenant!(u, fn -> {:ok, _} = Rows.ensure(u, v.id, "Y") end)
    [y] = tenant!(u, fn -> Rows.ids_at(u, v.id, ["Y"]) end)

    Repo.query!("UPDATE folders SET full_path_hmac = $1 WHERE id = $2", [
      Rows.path_hmac(fk, "A/B"),
      Ecto.UUID.dump!(y)
    ])

    Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(b)])

    assert {:ok, %{deleted: 1}} = Notes.delete_folder(u, v, "A")

    assert %{rows: [[%NaiveDateTime{}]]} =
             Repo.query!("SELECT deleted_at FROM notes WHERE id = $1", [Ecto.UUID.dump!(b)])
  end

  # `repair` with the stop on sets only the explicit flag: a racing creator's
  # row keeps the hash it was written with. Red before: it wrote the (nil)
  # hash over it.
  test "on: repair keeps a racing row's hash, sets explicit", ctx do
    %{user: u, vault: v, fk: fk} = ctx
    tenant!(u, fn -> {:ok, _} = Rows.ensure(u, v.id, "A") end)
    [a] = tenant!(u, fn -> Rows.ids_at(u, v.id, ["A"]) end)
    hash = Rows.path_hmac(fk, "A/B")

    racer =
      after_walk(fn ->
        Engram.FolderRows.insert!(u, v, Rows.name_hmac(fk, "B"), parent: a, full_path_hmac: hash)
      end)

    :ok = tenant!(u, fn -> Rows.ensure_markers(u, v.id, [{"A/B", Ecto.UUID.generate()}]) end)

    assert %{explicit: true} = Engram.FolderRows.row(racer.())
    assert hashes(v)[racer.()] == hash
  end

  # A merge (rename onto a live folder) with the stop on writes no hash on
  # the rows it moves. Red before: they got their new path's hash.
  test "on: a merge writes no path hash", %{user: u, vault: v} do
    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["S/X/Z", "T"]) end)

    {:ok, :ok} =
      Rows.with_deferred_retires(fn ->
        {:ok, tenant!(u, fn -> Rows.rename(u, v.id, "S", "T") end)}
      end)

    assert %{"T/X/Z" => _} = Engram.FolderRows.tree(u)
    assert hashes(v) |> Map.values() |> Enum.all?(&is_nil/1)
  end

  # A restore with the stop on writes no path hash on the rows it revives.
  # Red before: it put each revived row's current path hash.
  test "on: a restore writes no path hash", %{user: u, vault: v} do
    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["A/B"]) end)
    op = Ecto.UUID.generate()
    assert tenant!(u, fn -> Rows.soft_delete(u, v.id, ["A"], op) end) >= 1
    assert tenant!(u, fn -> Rows.restore_op(u, v.id, op) end) >= 1

    assert %{"A/B" => _} = Engram.FolderRows.tree(u)
    assert hashes(v) |> Map.values() |> Enum.all?(&is_nil/1)
  end

  # A row restored with the stop on drops the hash it died with, so a vault
  # that falls back to D's writes holds no hash twice. Red before: the
  # revived row kept it while a live row (renamed under the stop) held the
  # same one.
  test "on: a restore drops the revived row's old hash", ctx do
    %{user: u, vault: v} = ctx
    inert! = fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, false) end
    on! = fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, true) end
    on_exit(on!)

    inert!.()
    tenant!(u, fn -> {:ok, _} = Rows.ensure(u, v.id, "A/B") end)
    op = Ecto.UUID.generate()
    assert tenant!(u, fn -> Rows.soft_delete(u, v.id, ["A"], op) end) >= 1
    tenant!(u, fn -> {:ok, _} = Rows.ensure(u, v.id, "A/B") end)

    on!.()
    :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "C") end)
    assert tenant!(u, fn -> Rows.restore_op(u, v.id, op) end) >= 1

    # The fallback: the vault is back on D's writes.
    inert!.()
    assert %{"A/B" => _, "C/B" => _} = Engram.FolderRows.tree(u)

    %{rows: dups} =
      Repo.query!(
        """
        SELECT full_path_hmac FROM folders
        WHERE vault_id = $1 AND deleted_at IS NULL AND full_path_hmac IS NOT NULL
        GROUP BY 1 HAVING count(*) > 1
        """,
        [Ecto.UUID.dump!(v.id)]
      )

    assert dups == []
  end

  # The walk_index_cond_test race: `insert` runs right after the ensure's
  # walk, as a racing creator would.
  defp after_walk(insert) do
    me = self()
    key = {__MODULE__, :after_walk, make_ref()}
    name = "after-walk-#{inspect(key)}"

    :telemetry.attach(
      name,
      [:engram, :repo, :query],
      fn _, _, %{query: sql}, _ ->
        if self() == me and sql =~ "WITH RECURSIVE q" and Process.get(key) == nil do
          Process.put(key, :running)
          Process.put(key, insert.())
          :telemetry.detach(name)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
    fn -> Process.get(key) end
  end
end
