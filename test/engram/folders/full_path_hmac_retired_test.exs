defmodule Engram.Folders.FullPathHmacRetiredTest do
  @moduledoc """
  S6 step 3, release J (Engram#2523): nothing writes or reads
  `folders.full_path_hmac`. The column and `folders_full_path` stay for the
  rollback target (release I) and are dropped by the next release, whose
  migration-gates reference check needs `lib/` free of the names.

  Red before J: the gated writer (`PathHmacs`, `PathHashStop`), the
  `FolderTable` pass and the DEK rotation all wrote the hash, and three
  ledgers read it.

  The last test is the rollback shape: release I's `ExplicitFolderReconcile`
  re-verifies daily and clears `explicit` on a live row with no
  `explicit_seq` and no live marker at the row's `full_path_hmac`. Every
  explicit row a J writer leaves must carry `explicit_seq`, so that walk
  (run here verbatim) never clears a folder J created, renamed or restored
  with a NULL hash.
  """
  use Engram.DataCase, async: false

  alias Engram.Crypto.UserDekRotation
  alias Engram.DataMigrations.FolderTable
  alias Engram.Folders
  alias Engram.Notes
  alias Engram.Workers.DataMigrationsRunner

  @terms ["full_path_hmac", "folders_full_path", "PathHmacs", "PathHashStop"]

  @retired [
    {Engram.DataMigrations.FolderMarkerDelete, "folder_marker_delete"},
    {Engram.DataMigrations.NoteFolderHashNull, "note_folder_hash_null"},
    {Engram.DataMigrations.ExplicitFolderReconcile, "explicit_folder_reconcile"}
  ]

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Retired", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp write!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "x", "mtime" => 1.0},
        actor: "api"
      )

    note
  end

  defp hashed(user_id) do
    Repo.query!(
      "SELECT count(*) FROM folders WHERE user_id = $1 AND full_path_hmac IS NOT NULL",
      [Ecto.UUID.dump!(user_id)]
    ).rows
    |> hd()
    |> hd()
  end

  test "lib/ never names the column, its index or the retired writer" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,exs}"),
          text = File.read!(path),
          term <- @terms,
          String.contains?(text, term),
          do: {path, term}

    assert offenders == []
  end

  test "the hash's ledgers are retired: unregistered, deleted, their done rows kept" do
    for {mod, _name} <- @retired do
      refute mod in DataMigrationsRunner.migrations(), inspect(mod)
      refute Code.ensure_loaded?(mod), inspect(mod)
    end

    # Release I reads these rows as done after a rollback: J never touches them.
    done_at = ~U[2026-11-20 00:00:00.000000Z]

    for {_mod, name} <- @retired do
      Repo.insert_all("data_migrations", [
        %{
          name: name,
          version: 1,
          completed_at: done_at,
          inserted_at: done_at,
          updated_at: done_at
        }
      ])
    end

    DataMigrationsRunner.perform(%Oban.Job{scheduled_at: DateTime.utc_now()})

    for {_mod, name} <- @retired do
      assert Engram.DataMigrations.completed_at(name, 1) == done_at, name
    end
  end

  test "no writer sets the hash: create, rename, merge, restore, FolderTable, DEK rotation",
       %{user: user, vault: vault} do
    write!(user, vault, "A/B/C/one.md")
    write!(user, vault, "M/two.md")
    {:ok, _} = Notes.create_folder_marker(user, vault, "E/F")
    assert {:ok, _} = Folders.rename(user, vault, "A", "Z")
    assert {:ok, _} = Folders.rename(user, vault, "Z/B", "M/B")
    op = Ecto.UUID.generate()
    assert {:ok, _} = Folders.delete(user, vault, "M", recursive: true, op_id: op)
    assert {:ok, _} = Folders.restore_op(user, vault, op)
    FolderTable.run_pass(user_ids: [user.id])
    assert :ok = UserDekRotation.rotate_user(user.id)

    %{rows: [[rows]]} =
      Repo.query!("SELECT count(*) FROM folders WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])

    assert rows > 5
    assert hashed(user.id) == 0
  end

  test "release I's explicit-flag reconcile clears no folder J made explicit",
       %{user: user, vault: vault} do
    # Markers stopped, as in prod from release E (`MarkerStop.on?/0`).
    Engram.ServiceConfig.put_override(:folder_marker_stop, true)

    {:ok, _} = Notes.create_folder_marker(user, vault, "Empty/Kept")
    {:ok, _} = Notes.create_folder_markers(user, vault, ["Batch/One", "Batch/Two"])
    write!(user, vault, "Full/n.md")
    {:ok, _} = Notes.create_folder_marker(user, vault, "Full")
    assert {:ok, _} = Folders.rename(user, vault, "Empty", "Moved")
    assert {:ok, _} = Folders.rename(user, vault, "Batch/One", "Full/One")
    op = Ecto.UUID.generate()
    assert {:ok, _} = Folders.delete(user, vault, "Batch", recursive: true, op_id: op)
    assert {:ok, _} = Folders.restore_op(user, vault, op)

    explicit =
      Repo.query!("SELECT count(*) FROM folders WHERE user_id = $1 AND explicit", [
        Ecto.UUID.dump!(user.id)
      ]).rows

    assert [[n]] = explicit
    assert n >= 4
    assert hashed(user.id) == 0
    assert Engram.ReleaseIReconcile.cleared_ids(user.id) == []
  end

  defp close_reconcile_ledger!,
    do: Engram.DataMigrations.mark_done("explicit_folder_reconcile", 1)

  defp explicit_folders(user, vault),
    do: elem(Notes.list_explicit_folders(user, vault), 1) |> Enum.sort()

  defp explicit_seqs(user_id) do
    Repo.query!(
      "SELECT explicit_seq FROM folders WHERE user_id = $1 AND explicit ORDER BY explicit_seq",
      [Ecto.UUID.dump!(user_id)]
    ).rows
    |> List.flatten()
  end

  # Prod's path: the reconcile ledger closed (release D on), so the boot run
  # clears nothing, even a row the rule would clear; it only stamps it, so
  # release I's walk then leaves it too.
  test "the boot reconcile clears nothing on a closed ledger, and stamps", %{
    user: user,
    vault: vault
  } do
    {:ok, %{folders: [%{id: marker}]}} = Notes.create_folder_markers(user, vault, ["Ghost"])
    Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(marker)])
    Repo.query!("UPDATE folders SET explicit_seq = NULL WHERE id = $1", [Ecto.UUID.dump!(marker)])
    assert [_] = Engram.ReleaseIReconcile.cleared_ids(user.id)

    close_reconcile_ledger!()
    Engram.ReleaseIReconcile.run!()

    assert explicit_folders(user, vault) == ["Ghost"]
    assert explicit_seqs(user.id) == [0]
    assert Engram.ReleaseIReconcile.cleared_ids(user.id) == []
  end

  defp folders_exclusive_locks do
    Repo.query!("""
    SELECT count(*) FROM pg_locks
    WHERE pid = pg_backend_pid() AND relation = 'folders'::regclass
      AND mode = 'AccessExclusiveLock'
    """).rows
    |> hd()
    |> hd()
  end

  # Delta review of #2707, M1: prod (both ledgers done) takes no lock at
  # boot. The sandbox transaction keeps every lock the step took until the
  # test ends, so pg_locks shows it.
  test "with the marker delete done, the boot step takes no lock and stamps nothing", %{
    user: user,
    vault: vault
  } do
    {:ok, %{folders: [%{id: id}]}} = Notes.create_folder_markers(user, vault, ["Kept"])
    Repo.query!("UPDATE folders SET explicit_seq = NULL WHERE id = $1", [Ecto.UUID.dump!(id)])
    close_reconcile_ledger!()
    Engram.DataMigrations.mark_done("folder_marker_delete", 1)

    Engram.ReleaseIReconcile.run!()

    assert folders_exclusive_locks() == 0
    assert explicit_seqs(user.id) == [nil]
  end

  test "with the marker delete open, the boot step stamps", %{user: user, vault: vault} do
    {:ok, %{folders: [%{id: id}]}} = Notes.create_folder_markers(user, vault, ["Kept"])
    Repo.query!("UPDATE folders SET explicit_seq = NULL WHERE id = $1", [Ecto.UUID.dump!(id)])
    close_reconcile_ledger!()

    Engram.ReleaseIReconcile.run!()

    assert explicit_seqs(user.id) == [0]
    assert Engram.ReleaseIReconcile.cleared_ids(user.id) == []
  end

  # Review of #2707, MEDIUM 1: a self-host keeps its markers
  # (`folder_marker_delete` ships off) and their explicit rows carry no
  # `explicit_seq`. Under J a root-only rename leaves the descendants' hashes
  # at the old path (their markers move), and a DEK rotation re-keys the
  # markers but not the hashes: release I's walk, after a rollback, would
  # unlist both folders. The boot step's stamp keeps them.
  test "a self-host's marker-era rows survive a J rename and DEK rotation, rolled back to I",
       %{user: user, vault: vault} do
    {:ok, _} = Notes.create_folder_markers(user, vault, ["P", "P/Q"])

    # As release I left them: no stamp, each hash the one its marker carries.
    Repo.query!(
      """
      UPDATE folders AS f SET explicit_seq = NULL, full_path_hmac = n.folder_hmac
      FROM notes AS n WHERE n.id = f.id AND n.kind = 'folder' AND f.user_id = $1
      """,
      [Ecto.UUID.dump!(user.id)]
    )

    assert explicit_seqs(user.id) == [nil, nil]
    assert Engram.ReleaseIReconcile.cleared_ids(user.id) == []

    close_reconcile_ledger!()
    Engram.ReleaseIReconcile.run!()

    assert {:ok, _} = Folders.rename(user, vault, "P", "R")
    assert :ok = UserDekRotation.rotate_user(user.id)

    assert Engram.ReleaseIReconcile.cleared_ids(user.id) == []
    assert explicit_folders(user, vault) == ["R", "R/Q"]
  end

  # Review of #2707, MEDIUM 1 and 2: the markers J still writes (a skipping
  # self-host whose `folder_table` ledger is open, so `MarkerStop` is off) and
  # the rows `FolderTable` makes explicit from markers are stamped as written:
  # the boot stamp ran before them.
  test "rows J makes explicit from a marker are stamped", %{user: user, vault: vault} do
    Engram.ServiceConfig.put_override(:folder_marker_stop, true)
    Engram.ServiceConfig.put_override(:explicit_folders_ledger, :read)
    Engram.DataCase.clear_request_caches()
    refute Engram.Folders.MarkerStop.on?()

    {:ok, %{id: single}} = Notes.create_folder_marker(user, vault, "Open/One")
    {:ok, _} = Notes.create_folder_markers(user, vault, ["Open/Two"])
    assert explicit_seqs(user.id) == [0, 0]

    # FolderTable's present-row path: a marker whose row lost the flag.
    Repo.query!("UPDATE folders SET explicit = false, explicit_seq = NULL WHERE id = $1", [
      Ecto.UUID.dump!(single)
    ])

    FolderTable.run_pass(user_ids: [user.id])
    assert explicit_seqs(user.id) == [0, 0]

    assert {:ok, _} = Folders.rename(user, vault, "Open", "Shut")
    assert :ok = UserDekRotation.rotate_user(user.id)
    assert Engram.ReleaseIReconcile.cleared_ids(user.id) == []
  end
end
