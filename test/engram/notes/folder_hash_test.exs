defmodule Engram.Notes.FolderHashTest do
  # R9 release E: note writes stop setting `notes.folder_hmac` only once
  # `note_payload_stamps` is done (every Qdrant point has `n`), and set it
  # again when the ledger reopens, on this node and its peers. Uses the
  # ledger as it is on main (version 2): nothing here depends on R3.
  use Engram.DataCase, async: false

  alias Engram.DataMigrations
  alias Engram.DataMigrations.NotePayloadStamps, as: Stamps
  alias Engram.FolderRows
  alias Engram.Folders.Rows
  alias Engram.Notes
  alias Engram.Notes.FolderHash
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp note!(u, v, path) do
    {:ok, n} =
      Notes.upsert_note(u, v, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    n
  end

  defp hash_at(id) do
    %{rows: [[h]]} = Repo.query!("SELECT folder_hmac FROM notes WHERE id = $1", [dump(id)])
    h
  end

  # A node that cached the open answer sees done within the cache TTL (60 s);
  # the test does not wait it out.
  defp done! do
    :ok = DataMigrations.mark_done(Stamps.name(), Stamps.version())
    Engram.Cache.clear_local(:folder_hash_gate)
  end

  defp fk(u) do
    {:ok, fk} = Engram.Crypto.dek_filter_key(u)
    fk
  end

  test "the gate reads the ledger as it is on main (version 2)" do
    assert Stamps.version() == 2
  end

  describe "ledger open" do
    test "a create and a rename set the folder hash", %{user: u, vault: v} do
      n = note!(u, v, "A/n.md")
      assert hash_at(n.id) == Rows.path_hmac(fk(u), "A")

      {:ok, _} = Notes.rename_note(u, v, "A/n.md", "B/n.md")
      assert hash_at(n.id) == Rows.path_hmac(fk(u), "B")
    end
  end

  describe "ledger done" do
    setup do
      done!()
      :ok
    end

    test "a create in a folder writes NULL, its folder reference is set", %{user: u, vault: v} do
      n = note!(u, v, "A/n.md")
      assert hash_at(n.id) == nil
      assert FolderRows.ref("notes", n.id) == FolderRows.tree(u)["A"].id
    end

    test "a rename writes NULL, never the old hash", %{user: u, vault: v} do
      DataMigrations.reopen(Stamps.name(), Stamps.version())
      n = note!(u, v, "A/n.md")
      assert hash_at(n.id) == Rows.path_hmac(fk(u), "A")

      done!()
      {:ok, _} = Notes.rename_note(u, v, "A/n.md", "B/n.md")
      assert hash_at(n.id) == nil
      assert FolderRows.ref("notes", n.id) == FolderRows.tree(u)["B"].id
    end

    test "a folder rename writes NULL on the notes it moves", %{user: u, vault: v} do
      DataMigrations.reopen(Stamps.name(), Stamps.version())
      n = note!(u, v, "A/S/n.md")
      assert hash_at(n.id) == Rows.path_hmac(fk(u), "A/S")

      done!()
      {:ok, _} = Notes.rename_folder(u, v, "A", "Z")
      assert hash_at(n.id) == nil
      assert FolderRows.ref("notes", n.id) == FolderRows.tree(u)["Z/S"].id
    end

    test "a root note keeps its hash; a marker keeps its hash", %{user: u, vault: v} do
      n = note!(u, v, "top.md")
      assert hash_at(n.id) == Rows.path_hmac(fk(u), "")

      {:ok, marker} = Notes.create_folder_marker(u, v, "M")
      assert hash_at(marker.id) == Rows.path_hmac(fk(u), "M")
    end

    test "a reopen turns the hash back on", %{user: u, vault: v} do
      assert hash_at(note!(u, v, "A/n.md").id) == nil

      :ok = DataMigrations.reopen(Stamps.name(), Stamps.version())
      assert hash_at(note!(u, v, "A/m.md").id) == Rows.path_hmac(fk(u), "A")
    end

    # A peer's reopen arrives as the cache-sync message `reopen/2`
    # broadcasts; `Engram.Cache.Server` applies it on every node.
    test "a peer's reopen turns the hash back on this node" do
      refute FolderHash.write?()

      # The peer's `note_open/2` cleared the row; then its broadcast lands.
      Repo.update_all(DataMigrations.Entry, set: [completed_at: nil])
      refute FolderHash.write?(), "this node still trusts its cached done"

      send(
        Process.whereis(Engram.Cache.Server),
        {:cache_sync, {:data_migration_reopen, Stamps.name(), Stamps.version()}}
      )

      _ = :sys.get_state(Engram.Cache.Server)
      assert FolderHash.write?()
    end
  end

  defp flush_ledger_reads do
    receive do
      :ledger_read -> flush_ledger_reads()
    after
      0 -> :ok
    end
  end

  describe "cost per write" do
    setup do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "folder-hash-#{inspect(ref)}",
        [:engram, :repo, :query],
        fn _, _, meta, _ ->
          if meta[:source] == "data_migrations", do: send(parent, :ledger_read)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("folder-hash-#{inspect(ref)}") end)
      :ok
    end

    test "done: no ledger read" do
      done!()
      assert Stamps.done?()
      flush_ledger_reads()
      for _ <- 1..100, do: refute(FolderHash.write?())
      refute_received :ledger_read
    end

    test "open: at most one ledger read for many writes" do
      for _ <- 1..100, do: assert(FolderHash.write?())
      assert_received :ledger_read
      refute_received :ledger_read
    end
  end
end
