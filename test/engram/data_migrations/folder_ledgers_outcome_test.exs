defmodule Engram.DataMigrations.FolderLedgersOutcomeTest do
  # #2678: what the two folder ledgers change, on one fixture of every row
  # kind (from the #2678 review's equivalence check), at several window
  # sizes, against fixed expected rows. The statements were rewritten for
  # their plans (keyed reads); this pins that the rows they act on did not
  # move: the review measured the same rows for the 0.91.0 statements.
  #
  # Per tenant (one vault each): Kept (marker + explicit row), Ghost (marker gone, row kept
  # explicit: 0.89.0's ghost), E (`explicit_seq` set, no marker: made after
  # markers stopped), Trash (marker and row trashed), Gone (marker gone),
  # Mv/Sub renamed to Moved/Sub, NoHash (the row's path hash wiped), Plain/x,
  # and a note-derived folder.
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations
  alias Engram.DataMigrations.{ExplicitFolderReconcile, FolderMarkerDelete}
  alias Engram.{FolderRows, Notes, Repo}

  setup do
    # Markers present: writes keep the path hashes the ledgers match.
    Application.put_env(:engram, :path_hash_stop_markers_gone, false)
    on_exit(fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, true) end)

    on_exit(fn ->
      for mod <- [ExplicitFolderReconcile, FolderMarkerDelete],
          do: DataMigrations.forget(mod.name(), mod.version())
    end)

    :ok
  end

  defp d(id), do: Ecto.UUID.dump!(id)
  defp row(u, p), do: FolderRows.tree(u)[p].id

  defp tomb_marker!(u, p) do
    Repo.query!(
      "UPDATE notes SET deleted_at = now() WHERE kind = 'folder' AND user_id = $1 " <>
        "AND deleted_at IS NULL AND folder_hmac = (SELECT full_path_hmac FROM folders WHERE id = $2)",
      [d(u.id), d(row(u, p))]
    )
  end

  defp fixture!(u, v) do
    {:ok, _} =
      Notes.create_folder_markers(u, v, [
        "Kept",
        "Ghost",
        "E",
        "Trash",
        "Gone",
        "Mv/Sub",
        "NoHash",
        "Plain/x"
      ])

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Derived/n.md", "content" => "x"}, actor: "api")

    tomb_marker!(u, "Ghost")
    tomb_marker!(u, "E")
    Repo.query!("UPDATE folders SET explicit_seq = 7 WHERE id = $1", [d(row(u, "E"))])
    tomb_marker!(u, "Trash")
    Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [d(row(u, "Trash"))])
    Repo.query!("UPDATE folders SET full_path_hmac = NULL WHERE id = $1", [d(row(u, "NoHash"))])
    {:ok, _} = Notes.rename_folder(u, v, "Mv", "Moved")
    tomb_marker!(u, "Gone")
    :ok
  end

  # Four tenants, one vault each (`FolderRows.tree/1` is keyed by path per
  # user, so one vault a tenant keeps every row addressable).
  defp tenants! do
    for _ <- 1..4 do
      {:ok, u} = Engram.Fixtures.user_with_dek_fixture()
      v = insert(:vault, user: u)
      fixture!(u, v)
      {u, [v]}
    end
  end

  # `{user id, path}` of every live folder row of `users` matching `where`.
  defp rows_where(users, where) do
    for u <- users,
        {path, %{id: id}} <- FolderRows.tree(u),
        Repo.query!("SELECT 1 FROM folders WHERE id = $1 AND #{where}", [d(id)]).rows != [],
        do: {u.id, path}
  end

  defp expect(users, paths), do: Enum.sort(for u <- users, p <- paths, do: {u.id, p})

  defp run_until_done(mod, batch) do
    IdWindows.reset_walk(mod.name())
    DataMigrations.forget(mod.name(), mod.version())

    Enum.reduce_while(1..50, nil, fn _, _ ->
      case mod.run_pass(batch: batch) do
        :done -> {:halt, :done}
        more -> {:cont, more}
      end
    end)
  end

  defp in_rollback(fun) do
    {:error, {:result, result}} =
      Repo.transaction(fn -> Repo.rollback({:result, fun.()}) end)

    result
  end

  test "reconcile clears Ghost, Gone and NoHash in every vault, at every window size" do
    tenants = tenants!()
    users = Enum.map(tenants, &elem(&1, 0))
    explicit_before = rows_where(users, "explicit")

    for batch <- [1, 3, 7, 50, 200] do
      {cleared, kept} =
        in_rollback(fn ->
          assert run_until_done(ExplicitFolderReconcile, batch) == :done
          {explicit_before -- rows_where(users, "explicit"), rows_where(users, "explicit")}
        end)

      assert Enum.sort(cleared) == expect(users, ["Ghost", "Gone", "NoHash"]), "batch #{batch}"

      assert Enum.sort(kept) == expect(users, ["E", "Kept", "Moved/Sub", "Plain/x"]),
             "batch #{batch}"
    end
  end

  test "marker delete stamps and deletes the same rows at every window size" do
    tenants = tenants!()
    users = Enum.map(tenants, &elem(&1, 0))

    for {u, vaults} <- tenants, v <- vaults do
      # Markers of rows that are not live and explicit are tombstoned first,
      # as the reconcile leaves them (NoHash's has no row to match).
      tomb_marker!(u, "NoHash")

      Repo.query!(
        "UPDATE notes SET deleted_at = now() WHERE kind = 'folder' AND vault_id = $1 " <>
          "AND deleted_at IS NULL AND folder_hmac NOT IN (SELECT full_path_hmac FROM folders " <>
          "WHERE vault_id = $1 AND full_path_hmac IS NOT NULL AND explicit AND deleted_at IS NULL)",
        [d(v.id)]
      )
    end

    # An unmatched vault (a live marker with no explicit row) and an
    # already stamped row with a live marker.
    {:ok, u3} = Engram.Fixtures.user_with_dek_fixture()
    v3 = insert(:vault, user: u3)
    {:ok, _} = Notes.create_folder_markers(u3, v3, ["Un", "Ok"])
    Repo.query!("UPDATE folders SET explicit = false WHERE id = $1", [d(row(u3, "Un"))])
    {:ok, u4} = Engram.Fixtures.user_with_dek_fixture()
    v4 = insert(:vault, user: u4)
    {:ok, _} = Notes.create_folder_markers(u4, v4, ["S"])
    Repo.query!("UPDATE folders SET explicit_seq = 3 WHERE id = $1", [d(row(u4, "S"))])

    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_marker_stop, true)
    Engram.ServiceConfig.put_override(:marker_delete_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_marker_delete, true)
    Engram.ServiceConfig.put_override(:folder_marker_delete_max_fixed, 100_000)

    all = users ++ [u3, u4]

    for batch <- [200, 3, 1] do
      {stamped, markers} =
        in_rollback(fn ->
          IdWindows.reset_walk(FolderMarkerDelete.name())
          for _ <- 1..5, do: FolderMarkerDelete.run_pass(batch: batch)

          %{rows: m} =
            Repo.query!(
              "SELECT user_id, count(*)::int FROM notes WHERE kind = 'folder' " <>
                "AND deleted_at IS NULL AND user_id = ANY($1) GROUP BY user_id",
              [Enum.map(all, &d(&1.id))]
            )

          {rows_where(all, "explicit_seq = 0"),
           Enum.map(m, fn [u, n] -> [Ecto.UUID.load!(u), n] end)}
        end)

      assert Enum.sort(stamped) == expect(users, ["Kept", "Moved/Sub", "Plain/x"]),
             "batch #{batch}"

      # Only the unmatched vault's two markers stay live.
      assert markers == [[u3.id, 2]], "batch #{batch}"
    end
  end
end
