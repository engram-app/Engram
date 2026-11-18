defmodule Engram.Folders.WriteStopTest do
  # O(1) folder rename plan, S5 (Engram#2523): a folder rename or move writes
  # ONE folder row (`notes_cascaded = false`) at one seq, and nothing per
  # note: no note row, no tombstone, no per-note broadcast, one link chain.
  # Every reader then finds the notes where the folder row puts them.
  use EngramWeb.ConnCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.{Crypto, Folders, Notes, QueryRecorder, Repo, ServiceConfig}
  alias Engram.Folders.{Folder, WriteStop}
  alias Engram.MCP.Handlers

  @n 12

  setup :authed_api_conn

  setup %{user: user, vault: vault} do
    {:ok, user} = Crypto.ensure_user_dek(user)
    ServiceConfig.put_override(:folder_ops, true)

    for i <- 1..@n, do: put!(user, vault, "A/n#{i}.md", "note #{i}")
    put!(user, vault, "A/sub/deep.md", "deep")
    put!(user, vault, "Other/o.md", "other")

    %{user: user, vault: vault}
  end

  defp put!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  # Every note row of the vault, live or not, as the columns a cascade writes.
  defp note_rows(vault) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id, seq, path_hmac, path_ciphertext, folder_ref_id, deleted_at, updated_at " <>
          "FROM notes WHERE vault_id = $1 ORDER BY id",
        [Ecto.UUID.dump!(vault.id)]
      )

    rows
  end

  defp folder_row(user, vault, path) do
    Repo.with_tenant!(user.id, fn ->
      id = Folders.Rows.ids_by_path(user, vault.id, [path])
      Repo.get!(Folder, id[path])
    end)
  end

  defp current_seq(vault),
    do: Repo.with_tenant!(vault.user_id, fn -> Engram.Vaults.raw_current_seq(vault.id) end)

  # This test's own write statements to `table` (the recorder sees every
  # process's queries).
  defp writes_to(queries, table) do
    me = self()

    Enum.filter(queries, fn q ->
      q.pid == me and q.sql =~ ~r/^\s*(UPDATE|INSERT INTO|DELETE FROM)\s+"?#{table}"?\b/i
    end)
  end

  describe "a folder rename writes one folder row" do
    test "no note row changes, no tombstone, one seq", %{user: u, vault: v} do
      before = note_rows(v)

      {{:ok, %{notes: moved, seq: seq}}, queries} =
        QueryRecorder.record(fn -> Folders.rename(u, v, "A", "B") end)

      assert moved == @n + 1
      assert note_rows(v) == before
      assert writes_to(queries, "notes") == []

      row = folder_row(u, v, "B")
      refute row.notes_cascaded
      assert row.seq == seq
      assert seq == current_seq(v)
      # The renamed row, its name-terms stamp (same row), its subfolders'
      # path keys in one statement (O(subfolders); S6 drops the column), and
      # one statement releasing those hashes from any stale holder (one path
      # hash per live row, for 0.89.0 nodes in a mixed window).
      assert length(writes_to(queries, "folders")) == 4
    end

    test "a move across parents is the same one row", %{user: u, vault: v} do
      before = note_rows(v)
      assert {:ok, _} = Folders.rename(u, v, "A/sub", "Other/sub")
      assert note_rows(v) == before
      refute folder_row(u, v, "Other/sub").notes_cascaded
      assert {:ok, %{path: "Other/sub/deep.md"}} = Notes.get_note(u, v, "Other/sub/deep.md")
    end

    test "the cost does not grow with the folder", %{user: u, vault: v} do
      # The same shape as "A" (one subfolder), more than three times the notes.
      for i <- 1..40, do: put!(u, v, "Big/n#{i}.md", "b")
      put!(u, v, "Big/sub/s.md", "s")

      count = fn from, to ->
        {{:ok, _}, qs} = QueryRecorder.record(fn -> Folders.rename(u, v, from, to) end)
        length(writes_to(qs, "notes")) + length(writes_to(qs, "folders"))
      end

      small = count.("A", "A2")
      big = count.("Big", "Big2")
      assert big == small
    end

    test "one link chain, not one per note", %{user: u, vault: v} do
      put!(u, v, "index.md", "[[A/n1]] [[A/n2]] [[A/sub/deep]]")
      before = all_enqueued(worker: Engram.Workers.RewriteNoteLinks)

      assert {:ok, _} = Folders.rename(u, v, "A", "B")

      # One chain (up to 1,000 moved notes), carrying the folder's old path
      # once, as ciphertext: no tombstone exists to recover it from.
      jobs = all_enqueued(worker: Engram.Workers.RewriteNoteLinks) -- before
      assert [%{args: args}] = jobs
      assert length(args["targets"]) == @n + 1
      assert args["folder_move"]["folder_id"] == folder_row(u, v, "B").id
      refute inspect(args) =~ "n1.md"
    end
  end

  describe "every reader finds the notes at their new paths" do
    setup %{user: u, vault: v} do
      {:ok, _} = Folders.rename(u, v, "A", "B")
      :ok
    end

    test "by path, old path gone", %{user: u, vault: v} do
      assert {:ok, %{path: "B/n1.md", content: "note 1"}} = Notes.get_note(u, v, "B/n1.md")
      assert {:ok, %{path: "B/sub/deep.md"}} = Notes.get_note(u, v, "B/sub/deep.md")
      assert {:error, :not_found} = Notes.get_note(u, v, "A/n1.md")
      assert {:ok, %{path: "Other/o.md"}} = Notes.get_note(u, v, "Other/o.md")
    end

    test "by id and the CRDT channel's live path", %{user: u, vault: v} do
      {:ok, note} = Notes.get_note(u, v, "B/n3.md")
      assert {:ok, %{path: "B/n3.md"}} = Notes.get_note_by_id(u, v, note.id)
      assert Notes.live_note_path(u, v, note.id) == {:ok, "B/n3.md"}
    end

    test "manifest and tree", %{conn: conn} do
      paths =
        conn
        |> get(~p"/api/sync/manifest")
        |> json_response(200)
        |> Map.fetch!("notes")
        |> Enum.map(& &1["path"])

      assert "B/n1.md" in paths and "B/sub/deep.md" in paths
      refute Enum.any?(paths, &String.starts_with?(&1, "A/"))

      tree = conn |> get(~p"/api/vault/tree") |> json_response(200)
      tree_paths = Enum.map(tree["notes"], & &1["path"])
      assert "B/n1.md" in tree_paths
      refute Enum.any?(tree_paths, &String.starts_with?(&1, "A/"))
    end

    test "MCP list_folder", %{user: u, vault: v} do
      assert {:ok, text, _} = Handlers.handle("list_folder", u, v, %{"folder" => "B"})
      assert text =~ "n1"
      assert {:ok, gone, _} = Handlers.handle("list_folder", u, v, %{"folder" => "A"})
      refute gone =~ "n1"
    end

    test "a new note at the old path is a new note", %{user: u, vault: v} do
      {:ok, moved} = Notes.get_note(u, v, "B/n1.md")
      fresh = put!(u, v, "A/n1.md", "fresh")
      assert fresh.id != moved.id
      assert {:ok, %{content: "fresh"}} = Notes.get_note(u, v, "A/n1.md")
      assert {:ok, %{id: id, content: "note 1"}} = Notes.get_note(u, v, "B/n1.md")
      assert id == moved.id
    end

    test "a note renamed onto the old path takes it", %{user: u, vault: v} do
      assert {:ok, _} = Notes.rename_note(u, v, "Other/o.md", "A/n2.md")
      assert {:ok, %{content: "other"}} = Notes.get_note(u, v, "A/n2.md")
      assert {:ok, %{content: "note 2"}} = Notes.get_note(u, v, "B/n2.md")
    end

    test "an edit at the new path heals the stored path", %{user: u, vault: v} do
      put!(u, v, "B/n4.md", "edited")
      assert {:ok, %{path: "B/n4.md", content: "edited"}} = Notes.get_note(u, v, "B/n4.md")
      assert {:error, :not_found} = Notes.get_note(u, v, "A/n4.md")
    end
  end

  describe "the cascade still serves what S5 cannot yet" do
    test "folder_ops off: today's cascade", %{user: u, vault: v} do
      ServiceConfig.put_override(:folder_ops, false)
      before = note_rows(v)
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      assert note_rows(v) != before
      assert folder_row(u, v, "B").notes_cascaded
    end

    test "kill switch off: today's cascade", %{user: u, vault: v} do
      ServiceConfig.put_override(:folder_write_stop, false)
      refute WriteStop.on?()
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      assert folder_row(u, v, "B").notes_cascaded
    end

    test "a stale name stamp under the folder: cascade", %{user: u, vault: v} do
      Repo.query!("UPDATE notes SET name_stamp = NULL WHERE vault_id = $1", [
        Ecto.UUID.dump!(v.id)
      ])

      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      assert folder_row(u, v, "B").notes_cascaded
      assert {:ok, %{path: "B/n1.md"}} = Notes.get_note(u, v, "B/n1.md")
    end
  end

  describe "rows written before name_key" do
    test "their keys are filled, once, and the move stays one row", %{user: u, vault: v} do
      Repo.query!("UPDATE notes SET name_key = NULL WHERE vault_id = $1", [Ecto.UUID.dump!(v.id)])
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      refute folder_row(u, v, "B").notes_cascaded
      assert {:ok, %{path: "B/n1.md"}} = Notes.get_note(u, v, "B/n1.md")
      assert {:ok, %{path: "B/sub/deep.md"}} = Notes.get_note(u, v, "B/sub/deep.md")

      {{:ok, _}, queries} = QueryRecorder.record(fn -> Folders.rename(u, v, "B", "C") end)
      assert writes_to(queries, "notes") == []
      assert {:ok, %{path: "C/n1.md"}} = Notes.get_note(u, v, "C/n1.md")
    end

    test "a merge into a live folder: cascade", %{user: u, vault: v} do
      put!(u, v, "M/m.md", "m")
      assert {:error, :conflict} = Folders.rename(u, v, "A", "M")
    end
  end

  describe "rows S5 wrote, then a cascading writer (rollback to N-1)" do
    setup %{user: u, vault: v} do
      {:ok, _} = Folders.rename(u, v, "A", "B")
      :ok
    end

    test "a cascading rename of the moved folder lands every note", %{user: u, vault: v} do
      ServiceConfig.put_override(:folder_write_stop, false)
      assert {:ok, %{notes: n}} = Folders.rename(u, v, "B", "C")
      assert n == @n + 1
      assert {:ok, %{path: "C/n1.md"}} = Notes.get_note(u, v, "C/n1.md")
      assert {:ok, %{path: "C/sub/deep.md"}} = Notes.get_note(u, v, "C/sub/deep.md")
      assert {:error, :not_found} = Notes.get_note(u, v, "B/n1.md")
      assert {:error, :not_found} = Notes.get_note(u, v, "A/n1.md")
    end

    test "a folder delete of the moved folder deletes its notes", %{user: u, vault: v} do
      assert {:ok, %{notes: n}} = Folders.delete(u, v, "B", recursive: true)
      assert n == @n + 1
      assert {:error, :not_found} = Notes.get_note(u, v, "B/n1.md")
      assert {:ok, _} = Notes.get_note(u, v, "Other/o.md")
    end

    test "a second uncascaded rename keeps every path", %{user: u, vault: v} do
      before = note_rows(v)
      assert {:ok, _} = Folders.rename(u, v, "B/sub", "Other/sub2")
      assert {:ok, _} = Folders.rename(u, v, "B", "E")
      assert note_rows(v) == before
      assert {:ok, %{path: "E/n1.md"}} = Notes.get_note(u, v, "E/n1.md")
      assert {:ok, %{path: "Other/sub2/deep.md"}} = Notes.get_note(u, v, "Other/sub2/deep.md")
    end
  end
end
