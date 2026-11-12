defmodule Engram.Notes.LocationTest do
  # O(1) folder rename plan, S3 read switch (Engram#2523). The suite runs in
  # prod's state: the S2 `note_name` ledger done and `name_reads` on
  # (`config/test.exs`); `names_off!/0` is the fallback.
  #
  # While writers still cascade, the stored path is the truth. The folder
  # chain plus the name is read only in a vault holding a folder renamed
  # without a cascade (`folders.notes_cascaded = false`, the S5 write shape;
  # `mark_moved!/2`), and there only when no row holds the asked path. Every
  # other vault reads exactly as 0.83.0 did. A live note is shown where its
  # folder row puts it only when a folder on its own chain moved that way.
  #
  # async: false: the ledger answer is a node-wide cache entry.
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Folders.Rows
  alias Engram.Notes
  alias Engram.Notes.{Location, Name}
  alias Engram.Repo
  alias Engram.ServiceConfig

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "A/B/x.md", "content" => "# X\n\nbody"},
        actor: "api"
      )

    Engram.Cache.clear_local(:note_name)
    on_exit(fn -> Engram.Cache.clear_local(:note_name) end)
    %{user: user, vault: vault, note: note}
  end

  # The ledger as the test DB holds it (not done): names off.
  defp names_off! do
    ServiceConfig.put_override(:name_reads_ledger, :read)
    Engram.Cache.clear_local(:note_name)
    refute Location.on?()
  end

  defp sql!(sql, params), do: Repo.query!(sql, params)

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp note!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => path}, actor: "api")

    note
  end

  # The path key of the row no longer names its path: a reader that still
  # matches `path_hmac` (or the trigger-derived `path_id`) cannot find it.
  defp corrupt_path_key!(id) do
    sql!("UPDATE notes SET path_hmac = $2 WHERE id = $1", [
      dump(id),
      :crypto.strong_rand_bytes(32)
    ])
  end

  # Drift: the row's folder ref names another folder than its stored path.
  defp point_ref!(note_id, folder_id),
    do:
      sql!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [dump(note_id), dump(folder_id)])

  # A folder rename that writes ONE folder row and nothing else (the S5
  # write shape, `notes_cascaded = false`): the notes under it keep their
  # old stored path.
  defp move_folder_row!(user, folder_id, new_name) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    {ct, nonce} = Rows.encrypt_name(dek, folder_id, new_name)

    %{rows: [[vault_id]]} =
      sql!(
        "UPDATE folders SET name_ciphertext = $2, name_nonce = $3, name_hmac = $4, " <>
          "notes_cascaded = false WHERE id = $1 RETURNING vault_id",
        [dump(folder_id), ct, nonce, Rows.name_hmac(fk, new_name)]
      )

    # Its own path key too (S5 keeps that one row's keys current).
    {:ok, path} =
      Repo.with_tenant!(user.id, fn ->
        Rows.path_by_id(user, Ecto.UUID.load!(vault_id), folder_id)
      end)

    sql!("UPDATE folders SET full_path_hmac = $2 WHERE id = $1", [
      dump(folder_id),
      Rows.path_hmac(fk, path)
    ])
  end

  # The vault holds a folder moved without a cascade (an empty marker
  # folder, so no note's chain changes).
  defp mark_moved!(user, vault) do
    {:ok, _} = Engram.Folders.create_markers(user, vault, ["Moved"])

    sql!("UPDATE folders SET notes_cascaded = false WHERE id = $1", [
      dump(folder_id(user, vault, "Moved"))
    ])
  end

  # Incompressible, so its stored size is its length.
  defp random_text(n),
    do: n |> :crypto.strong_rand_bytes() |> Base.encode64() |> binary_part(0, n)

  defp got_ids(user, vault, paths) do
    for {p, fetch} <- Notes.get_notes_within(user, vault, paths, 10_000_000), into: %{} do
      {p, with(%{id: id} <- fetch.(), do: id)}
    end
  end

  defp folder_id(user, vault, path),
    do: Repo.with_tenant!(user.id, fn -> Rows.ids_by_path(user, vault.id, [path]) end)[path]

  defp found(user, vault, path) do
    case Notes.get_note(user, vault, path) do
      {:ok, note} -> note.id
      {:error, :not_found} -> nil
    end
  end

  test "the suite runs with names on, as prod does" do
    assert Location.on?()
  end

  # The ledger row, not the test config, turns names on in prod.
  test "a completed note_name ledger row turns names on; a reopen turns them off" do
    ServiceConfig.put_override(:name_reads_ledger, :read)
    Engram.Cache.clear_local(:note_name)
    refute Location.on?()

    :ok = Engram.DataMigrations.mark_done("note_name", 1)
    Engram.Cache.clear_local(:note_name)
    assert Location.on?()

    Engram.DataMigrations.reopen("note_name", 1)
    Engram.Cache.clear_local(:note_name)
    refute Location.on?()
  end

  describe "by-path lookup" do
    test "a vault with no moved folder reads stored paths only, as 0.83.0",
         %{user: u, vault: v, note: note} do
      corrupt_path_key!(note.id)
      assert found(u, v, "A/B/x.md") == nil
    end

    test "no row holds the path in a moved vault: the folder chain and the name find the note",
         %{user: u, vault: v, note: note} do
      mark_moved!(u, v)
      corrupt_path_key!(note.id)
      assert found(u, v, "A/B/x.md") == note.id
      assert Notes.note_exists?(u, v, "A/B/x.md")

      names_off!()
      assert found(u, v, "A/B/x.md") == nil
    end

    test "a folder moved with no cascade: found at the new path, and at the stored one",
         %{user: u, vault: v, note: note} do
      move_folder_row!(u, folder_id(u, v, "A/B"), "C")

      assert found(u, v, "A/C/x.md") == note.id
      # Writers still cascade, so the stored path stays authoritative.
      assert found(u, v, "A/B/x.md") == note.id
      # The note reads back at the path it was found at.
      assert {:ok, %{path: "A/C/x.md", folder: "A/C"}} = Notes.get_note(u, v, "A/C/x.md")

      names_off!()
      assert found(u, v, "A/C/x.md") == nil
    end

    test "the name is exact: another case of the same name is a different path",
         %{user: u, vault: v, note: note} do
      mark_moved!(u, v)
      corrupt_path_key!(note.id)
      assert found(u, v, "A/B/x.md") == note.id
      assert found(u, v, "A/B/X.md") == nil
      assert found(u, v, "a/B/x.md") == nil
    end

    test "a stale name stamp (a previous-release rename) is never matched by name",
         %{user: u, vault: v, note: note} do
      {:ok, fk} = Crypto.dek_filter_key(u)

      # The previous release renamed y.md to x.md: new path, old name keys.
      sql!(
        "UPDATE notes SET name_hmac = $2, name_ci_hmac = $3, name_stamp = $4 WHERE id = $1",
        [dump(note.id), Name.hmac(fk, "y.md"), Name.ci_hmac(fk, "y.md"), <<9, 9, 9>>]
      )

      assert found(u, v, "A/B/x.md") == note.id
      assert found(u, v, "A/B/y.md") == nil
    end

    test "a row with no folder ref is read by its path", %{user: u, vault: v, note: note} do
      root = note!(u, v, "r.md")
      sql!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [dump(note.id)])

      assert found(u, v, "r.md") == root.id
      assert found(u, v, "A/B/x.md") == note.id
    end

    test "unfinished ledger: names are not read", %{user: u, vault: v, note: note} do
      move_folder_row!(u, folder_id(u, v, "A/B"), "C")
      names_off!()
      assert found(u, v, "A/B/x.md") == note.id
      assert found(u, v, "A/C/x.md") == nil
    end

    test "the name_reads override turns names off", %{user: u, vault: v, note: note} do
      move_folder_row!(u, folder_id(u, v, "A/B"), "C")
      ServiceConfig.put_override(:name_reads, false)
      refute Location.on?()
      assert found(u, v, "A/C/x.md") == nil
      assert found(u, v, "A/B/x.md") == note.id
    end

    test "get_notes_within (MCP get_notes) resolves each path, the stored path first",
         %{user: u, vault: v, note: note} do
      other = note!(u, v, "D/x.md")
      move_folder_row!(u, folder_id(u, v, "A/B"), "C")

      got =
        u
        |> Notes.get_notes_within(v, ["D/x.md", "A/C/x.md", "A/B/x.md", "nope.md"], 1_000_000)
        |> Enum.map(fn {path, fetch} -> {path, with(%{id: id} <- fetch.(), do: id)} end)

      assert got == [
               {"D/x.md", other.id},
               {"A/C/x.md", note.id},
               {"A/B/x.md", note.id},
               {"nope.md", nil}
             ]
    end
  end

  describe "drift (a folder ref that disagrees with the stored path)" do
    setup %{user: u, vault: v, note: note} do
      z = note!(u, v, "Z/z.md")
      point_ref!(note.id, folder_id(u, v, "Z"))
      %{z: z}
    end

    test "the note is found at its stored path only", %{user: u, vault: v, note: note} do
      assert found(u, v, "A/B/x.md") == note.id
      assert found(u, v, "Z/x.md") == nil
    end

    test "a push to the stored path updates the note; a rename onto it conflicts",
         %{user: u, vault: v, note: note} do
      assert {:ok, %{id: id}} =
               Notes.upsert_note(u, v, %{"path" => "A/B/x.md", "content" => "new"}, actor: "api")

      assert id == note.id
      _ = note!(u, v, "D/o.md")
      assert {:error, :conflict} = Notes.rename_note(u, v, "D/o.md", "A/B/x.md")
    end

    # Review B2, scenario 1: a new note at the drift row's folder-ref path.
    test "a new note at the folder ref's path is a new row; the drift note is untouched",
         %{user: u, vault: v, note: note} do
      assert {:ok, %{id: id}} =
               Notes.upsert_note(u, v, %{"path" => "Z/x.md", "content" => "zzz"}, actor: "api")

      refute id == note.id
      assert {:ok, %{id: ^id, content: "zzz"}} = Notes.get_note(u, v, "Z/x.md")
      assert {:ok, %{content: "# X\n\nbody"}} = Notes.get_note(u, v, "A/B/x.md")
    end

    # Review B2, scenario 2: a replayed delete.
    test "a replayed delete of the folder ref's path deletes nothing more",
         %{user: u, vault: v, note: note} do
      _ = note!(u, v, "Z/x.md")
      assert :deleted = Notes.delete_note_reporting(u, v, "Z/x.md")
      assert :absent = Notes.delete_note_reporting(u, v, "Z/x.md")
      assert found(u, v, "A/B/x.md") == note.id
    end

    # Review B2, scenario 3: a CRDT create mints the file's own id.
    test "a CRDT create at the folder ref's path does not adopt the drift note",
         %{user: u, vault: v, note: note} do
      fresh = Notes.mint_id()
      assert {:ok, %{id: ^fresh}} = Notes.genesis_crdt_note(u, v, fresh, "Z/x.md")
      assert found(u, v, "A/B/x.md") == note.id
    end

    test "in a moved vault the row holding the path wins over a name match",
         %{user: u, vault: v, note: note} do
      holder = note!(u, v, "Z/x.md")
      mark_moved!(u, v)

      assert found(u, v, "Z/x.md") == holder.id
      assert :deleted = Notes.delete_note_reporting(u, v, "Z/x.md")
      assert found(u, v, "A/B/x.md") == note.id
    end

    test "in a moved vault two name matches and no holder give the lowest id",
         %{user: u, vault: v, note: note} do
      other = note!(u, v, "Z/x.md")
      corrupt_path_key!(other.id)
      mark_moved!(u, v)
      assert found(u, v, "Z/x.md") == Enum.min([note.id, other.id])
    end

    # Review M5: the rename's claim check and its row check read the same
    # lookup, so a target the row check calls taken is never claimed first.
    test "in a moved vault a rename onto a name-matched path conflicts before any claim",
         %{user: u, vault: v} do
      _ = note!(u, v, "D/o.md")
      mark_moved!(u, v)
      me = self()
      id = "orphan-claim-#{System.unique_integer()}"

      :telemetry.attach(
        id,
        [:engram, :crdt, :index_claim],
        fn _, _, %{route: route}, _ -> send(me, {:claim_route, route}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:error, :conflict} = Notes.rename_note(u, v, "D/o.md", "Z/x.md")
      refute_received {:claim_route, :orphan}
    end

    # Third review B3: get_notes keyed a drift row by its folder-ref path too.
    test "get_notes over same-name paths serves the holder of the folder-ref path",
         %{user: u, vault: v, note: note} do
      holder = note!(u, v, "Z/x.md")
      got = got_ids(u, v, ["Z/x.md", "A/B/x.md"])
      assert got["A/B/x.md"] == note.id
      assert got["Z/x.md"] == holder.id
    end

    test "get_notes over same-name paths serves nothing at an unheld folder-ref path",
         %{user: u, vault: v, note: note} do
      got = got_ids(u, v, ["A/B/x.md", "Z/x.md"])
      assert got["A/B/x.md"] == note.id
      assert got["Z/x.md"] == nil
    end

    test "in a moved vault get_notes still serves the holder of a same-name path",
         %{user: u, vault: v, note: note} do
      holder = note!(u, v, "Z/x.md")
      mark_moved!(u, v)
      got = got_ids(u, v, ["Z/x.md", "A/B/x.md"])
      assert got["A/B/x.md"] == note.id
      assert got["Z/x.md"] == holder.id
    end

    # Fourth review m12: past the byte budget, a drift row read by the greedy
    # pass took the folder-ref path its holder had already answered (and a
    # drift row on the first page hid a holder past the cut).
    test "past the budget a drift row never replaces the holder of a path",
         %{user: u, vault: v, note: note} do
      holder = note!(u, v, "Z/x.md")

      {:ok, _} =
        Notes.upsert_note(u, v, %{"path" => "big.md", "content" => random_text(200_000)},
          actor: "api"
        )

      move_folder_row!(u, folder_id(u, v, "A"), "A")

      for paths <- [["Z/x.md", "big.md", "A/B/x.md"], ["A/B/x.md", "big.md", "Z/x.md"]] do
        got =
          for {p, fetch} <- Notes.get_notes_within(u, v, paths, 50_000), into: %{} do
            {p, with(%{id: id} <- fetch.(), do: id)}
          end

        assert got["Z/x.md"] == holder.id, inspect(paths)
        assert got["A/B/x.md"] == note.id, inspect(paths)
        assert got["big.md"] == :over_budget, inspect(paths)
      end
    end

    test "outputs keep the stored path under a cascaded folder", %{user: u, vault: v, note: note} do
      {:ok, %{changes: changes}} = Notes.list_changes_by_seq(u, v, 0)
      assert %{path: "A/B/x.md"} = Enum.find(changes, &(&1.id == note.id))
      assert {:ok, %{path: "A/B/x.md"}} = Notes.get_note_by_id(u, v, note.id)
    end
  end

  describe "cost" do
    test "get_notes_within at current stored paths reads no folder chains", %{user: u, vault: v} do
      _ = note!(u, v, "D/y.md")

      {got, queries} =
        Engram.QueryRecorder.record(fn ->
          for {_path, fetch} <- Notes.get_notes_within(u, v, ["A/B/x.md", "D/y.md"], 1_000_000),
              do: fetch.().path
        end)

      assert got == ["A/B/x.md", "D/y.md"]
      assert Engram.QueryPlan.reading(queries, "folders") == []
    end

    test "a feed page with no moved folder reads no folder rows", %{user: u, vault: v} do
      {_, queries} = Engram.QueryRecorder.record(fn -> Notes.list_changes_by_seq(u, v, 0) end)
      assert Engram.QueryPlan.reading(queries, "folders") == []
    end

    test "a feed page under a moved folder reads its chains in its own transaction",
         %{user: u, vault: v} do
      move_folder_row!(u, folder_id(u, v, "A/B"), "C")
      {_, queries} = Engram.QueryRecorder.record(fn -> Notes.list_changes_by_seq(u, v, 0) end)

      assert [_] = Engram.QueryPlan.reading(queries, "folders")

      assert Enum.any?(Engram.QueryRecorder.transactions(queries), fn sqls ->
               Enum.any?(sqls, &(&1 =~ ~s(FROM "notes"))) and
                 Enum.any?(sqls, &(&1 =~ ~s(FROM "folders")))
             end)
    end
  end

  describe "derived output paths" do
    test "the change feed serves the path its moved folder gives it, plus folder_id and name",
         %{user: u, vault: v, note: note} do
      b = folder_id(u, v, "A/B")
      move_folder_row!(u, b, "C")

      {:ok, %{changes: [change]}} = Notes.list_changes_by_seq(u, v, 0)
      assert change.id == note.id
      assert change.path == "A/C/x.md"
      assert change.folder == "A/C"
      assert change.folder_id == b
      assert change.name == "x.md"

      {:ok, %{changes: [meta]}} = Notes.list_changes_by_seq(u, v, 0, fields: :meta)
      assert meta.path == "A/C/x.md"

      names_off!()
      {:ok, %{changes: [before]}} = Notes.list_changes_by_seq(u, v, 0)
      assert before.path == "A/B/x.md"
      refute Map.has_key?(before, :folder_id)
    end

    test "get_note_by_id shows the derived path; the stored-row read keeps the stored one",
         %{user: u, vault: v, note: note} do
      move_folder_row!(u, folder_id(u, v, "A/B"), "C")

      assert {:ok, %{path: "A/C/x.md", folder: "A/C"}} = Notes.get_note_by_id(u, v, note.id)
      assert {:ok, %{path: "A/B/x.md"}} = Notes.get_note_row_by_id(u, v, note.id)
    end

    test "a folder listing (MCP list_folder) shows the derived paths", %{user: u, vault: v} do
      move_folder_row!(u, folder_id(u, v, "A/B"), "C")

      assert {:ok, %{notes: [%{path: "A/C/x.md"}]}} =
               Notes.list_notes_in_folder_page(u, v, "A/C")
    end

    test "a tombstone keeps the path it was deleted at", %{user: u, vault: v} do
      :ok = Notes.delete_note(u, v, "A/B/x.md")
      move_folder_row!(u, folder_id(u, v, "A/B"), "C")

      {:ok, %{changes: changes}} = Notes.list_changes_by_seq(u, v, 0)
      assert [%{deleted: true, path: "A/B/x.md"} = tomb] = Enum.filter(changes, & &1.deleted)
      refute Map.has_key?(tomb, :folder_id)
    end

    test "put_paths/3 derives moved rows across vaults and leaves the rest alone",
         %{user: u, vault: v, note: note} do
      v2 = insert(:vault, user: u)
      n2 = note!(u, v2, "A/B/x.md")
      move_folder_row!(u, folder_id(u, v, "A/B"), "C")

      # Stored rows as a reader decrypts them: the stored path, still A/B.
      notes = for {vv, n} <- [{v, note}, {v2, n2}], do: stored!(u, vv, n.id)
      assert Enum.map(notes, & &1.path) == ["A/B/x.md", "A/B/x.md"]

      assert [%{path: "A/C/x.md", folder: "A/C"}, %{path: "A/B/x.md"}] =
               Location.put_paths(u, notes)
    end
  end

  defp stored!(user, vault, id) do
    {:ok, note} = Notes.get_note_row_by_id(user, vault, id)
    note
  end
end
