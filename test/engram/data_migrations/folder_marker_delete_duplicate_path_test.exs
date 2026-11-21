defmodule Engram.DataMigrations.FolderMarkerDeleteDuplicatePathTest do
  # #2678 review: duplicate live folder rows at one (vault, full_path_hmac).
  # The marker probe (`@folders_at_marker`) reads them by that key and must
  # pick by tenant and `explicit` above its fence: another tenant's explicit
  # row at the marker's path must not match it (the vault would pass the
  # unmatched check and the owner's marker, so their empty folder, would go).
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations
  alias Engram.DataMigrations.FolderMarkerDelete
  alias Engram.{FolderRows, Notes, Repo}

  setup do
    Application.put_env(:engram, :path_hash_stop_markers_gone, false)
    on_exit(fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, true) end)

    on_exit(fn ->
      DataMigrations.forget(FolderMarkerDelete.name(), FolderMarkerDelete.version())
    end)

    :ok
  end

  defp d(id), do: Ecto.UUID.dump!(id)
  defp row(u, p), do: FolderRows.tree(u)[p].id

  defp rows(sql, args), do: Repo.query!(sql, args).rows

  # Dup (marker live) and Dup2 (marker tombstoned) whose row is moved onto
  # Dup's path hash; flags then set per case.
  defp fixture!(dup_flags, dup2_flags, dup2_owner) do
    {:ok, u} = Engram.Fixtures.user_with_dek_fixture()
    v = insert(:vault, user: u)
    {:ok, _} = Notes.create_folder_markers(u, v, ["Dup", "Dup2"])
    dup = row(u, "Dup")
    dup2 = row(u, "Dup2")

    Repo.query!(
      "UPDATE notes SET deleted_at = now() WHERE kind = 'folder' AND vault_id = $1 " <>
        "AND folder_hmac = (SELECT full_path_hmac FROM folders WHERE id = $2)",
      [d(v.id), d(dup2)]
    )

    Repo.query!(
      "UPDATE folders SET full_path_hmac = (SELECT full_path_hmac FROM folders WHERE id = $1) WHERE id = $2",
      [d(dup), d(dup2)]
    )

    Repo.query!("UPDATE folders SET #{dup_flags} WHERE id = $1", [d(dup)])
    Repo.query!("UPDATE folders SET #{dup2_flags} WHERE id = $1", [d(dup2)])

    if dup2_owner,
      do:
        Repo.query!("UPDATE folders SET user_id = $1 WHERE id = $2", [d(dup2_owner.id), d(dup2)])

    [[n]] =
      rows(
        "SELECT count(*)::int FROM notes WHERE kind = 'folder' AND deleted_at IS NULL AND vault_id = $1",
        [d(v.id)]
      )

    assert n == 1, "fixture: one live marker"
    {v, dup, dup2}
  end

  defp run! do
    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_marker_stop, true)
    Engram.ServiceConfig.put_override(:marker_delete_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_marker_delete, true)
    Engram.ServiceConfig.put_override(:folder_marker_delete_max_fixed, 100_000)
    IdWindows.reset_walk(FolderMarkerDelete.name())
    for b <- [1, 200], _ <- 1..3, do: FolderMarkerDelete.run_pass(batch: b)
  end

  defp state(v, dup, dup2) do
    [[live]] =
      rows(
        "SELECT count(*)::int FROM notes WHERE kind = 'folder' AND deleted_at IS NULL AND vault_id = $1",
        [d(v.id)]
      )

    seq = fn id -> hd(hd(rows("SELECT explicit_seq FROM folders WHERE id = $1", [d(id)]))) end
    {live, seq.(dup), seq.(dup2)}
  end

  for {name, a, b, foreign?, expect} <- [
        # own explicit + own non-explicit at one hash: matched, explicit row stamped
        {"explicit first", "explicit = true, explicit_seq = NULL", "explicit = false", false,
         {0, 0, nil}},
        {"explicit second", "explicit = false", "explicit = true, explicit_seq = NULL", false,
         {0, nil, 0}},
        # own non-explicit + another tenant's explicit: unmatched, nothing deleted
        {"foreign explicit", "explicit = false", "explicit = true, explicit_seq = NULL", true,
         {1, nil, nil}},
        # own explicit stamped + own explicit unstamped: both live explicit, unstamped one stamped
        {"two explicit", "explicit = true, explicit_seq = 5",
         "explicit = true, explicit_seq = NULL", false, {0, 5, 0}}
      ] do
    test "duplicate path hash: #{name}" do
      other = if unquote(foreign?), do: elem(Engram.Fixtures.user_with_dek_fixture(), 1)
      {v, dup, dup2} = fixture!(unquote(a), unquote(b), other)
      run!()
      assert state(v, dup, dup2) == unquote(Macro.escape(expect))
    end
  end
end
