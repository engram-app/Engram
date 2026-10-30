defmodule Engram.NotesVaultScanTest do
  # Whole-vault reads (2026-10-20 audit): tags, types and folder counts are
  # cached per vault change_seq, and a folder cascade fetches only the rows
  # under the folder.
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.QueryPlan
  alias Engram.QueryRecorder

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp put!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  # A write the cache cannot know about: its seq is rolled back over, the
  # way no app writer behaves. Only a fresh read of the vault finds it.
  defp sneak!(user, vault, path, content) do
    seq = Engram.Vaults.current_seq(user.id, vault.id)
    put!(user, vault, path, content)

    Repo.with_tenant!(user.id, fn ->
      Repo.query!("UPDATE vaults SET change_seq = $1 WHERE id = $2", [
        seq,
        Ecto.UUID.dump!(vault.id)
      ])
    end)
  end

  defp notes_reads(fun) do
    {result, queries} = QueryRecorder.record(fun)
    {result, QueryPlan.reading(queries, "notes")}
  end

  describe "tags" do
    test "counts by distinct tag set, weighted by the notes sharing it", %{user: u, vault: v} do
      for n <- 1..3, do: put!(u, v, "S#{n}.md", "---\ntags: [a, b]\n---\n#{n}")
      put!(u, v, "T.md", "---\ntags: [b, c]\n---")
      put!(u, v, "None.md", "no tags")

      assert {:ok, [%{name: "a", count: 3}, %{name: "b", count: 4}, %{name: "c", count: 1}]} =
               Notes.list_tags_with_counts(u, v)

      assert {:ok, ["a", "b", "c"]} = Notes.list_tags(u, v)
    end

    test "a second read at the same seq reads no notes; a write moves the seq", ctx do
      %{user: u, vault: v} = ctx
      put!(u, v, "A.md", "---\ntags: [a]\n---")
      assert {:ok, ["a"]} = Notes.list_tags(u, v)

      assert {{:ok, ["a"]}, []} = notes_reads(fn -> Notes.list_tags(u, v) end)

      put!(u, v, "B.md", "---\ntags: [b]\n---")
      assert {:ok, ["a", "b"]} = Notes.list_tags(u, v)
    end

    test "the cache key is the seq: a write that skipped it is not seen", %{user: u, vault: v} do
      put!(u, v, "A.md", "---\ntags: [a]\n---")
      assert {:ok, ["a"]} = Notes.list_tags(u, v)
      sneak!(u, v, "Hidden.md", "---\ntags: [hidden]\n---")
      assert {:ok, ["a"]} = Notes.list_tags(u, v)
    end
  end

  describe "types" do
    test "a second read at the same seq reads no notes; a write moves the seq", ctx do
      %{user: u, vault: v} = ctx
      put!(u, v, "A.md", "---\ntype: playbook\n---")
      assert {:ok, ["playbook"]} = Notes.list_types(u, v)
      assert {{:ok, ["playbook"]}, []} = notes_reads(fn -> Notes.list_types(u, v) end)

      put!(u, v, "B.md", "---\ntype: meeting\n---")
      assert {:ok, ["meeting", "playbook"]} = Notes.list_types(u, v)
    end
  end

  describe "folder counts" do
    test "list_folders_with_counts and folders_payload share one cached count", ctx do
      %{user: u, vault: v} = ctx
      put!(u, v, "Work/A.md", "a")
      assert {:ok, [%{folder: "Work", count: 1}]} = Notes.list_folders_with_counts(u, v)

      {payload, reads} = notes_reads(fn -> Notes.folders_payload(u, v) end)
      assert [%{name: "Work", count: 1}] = payload
      # Only the folder markers are read; the count came from the cache.
      assert [marker_read] = reads
      assert marker_read =~ ~s("kind" = 'folder')

      put!(u, v, "Work/B.md", "b")
      assert {:ok, [%{folder: "Work", count: 2}]} = Notes.list_folders_with_counts(u, v)
    end

    defp refer!(note_id, ref) do
      Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [
        Ecto.UUID.dump!(note_id),
        Ecto.UUID.dump!(ref)
      ])
    end

    defp delete_folder_row!(id) do
      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(id)])
    end

    # Every row kind the count distinguishes: a note in a live folder row,
    # one in a nested live row, notes whose reference names a DELETED row
    # (counted by their folder hash, two different dead rows under one hash
    # summed), a root note, a soft-deleted note, and an empty marker.
    test "counts live, nested, dead-ref, root and marker rows", %{user: u, vault: v} do
      put!(u, v, "Live/a.md", "a")
      put!(u, v, "Live/Deep/b.md", "b")
      d1 = put!(u, v, "Dead/c.md", "c")
      d2 = put!(u, v, "Dead/d.md", "d")
      put!(u, v, "root.md", "r")
      put!(u, v, "Live/gone.md", "g")
      :ok = Notes.delete_note(u, v, "Live/gone.md")
      {:ok, _} = Notes.create_folder_markers(u, v, ["Empty"])

      dead = Engram.FolderRows.ref("notes", d1.id)
      other_dead = Engram.FolderRows.insert!(u, v, :crypto.strong_rand_bytes(32))
      refer!(d2.id, other_dead)
      delete_folder_row!(dead)
      delete_folder_row!(other_dead)

      counts =
        Repo.with_tenant!(u.id, fn -> Notes.raw_folder_count_rows(u, v) end)
        |> Notes.decrypt_folder_count_rows(elem(Engram.Crypto.get_dek(u), 1))

      assert Map.new(counts, &{&1.folder, &1.count}) == %{
               "" => 1,
               "Live" => 1,
               "Live/Deep" => 1,
               "Dead" => 2,
               "Empty" => 0
             }
    end

    # R5: the old read scanned the vault's notes twice (by reference, then
    # the unreferenced rest), each with a correlated live-folder probe; the
    # by-reference half became a nested loop over every folder row (231 ms on
    # a 13k-folder staging vault). One grouped scan, liveness decided from the
    # folder rows already loaded.
    test "reads the vault's notes once", %{user: u, vault: v} do
      put!(u, v, "Work/A.md", "a")
      put!(u, v, "root.md", "r")

      {_, reads} =
        notes_reads(fn -> Repo.with_tenant!(u.id, fn -> Notes.raw_folder_count_rows(u, v) end) end)

      assert length(reads) == 1, "notes reads:\n#{Enum.join(reads, "\n")}"
    end
  end

  describe "folder cascade" do
    setup %{user: u, vault: v} do
      put!(u, v, "Work/A.md", "a")
      put!(u, v, "Work/Sub/B.md", "b")
      put!(u, v, "Home/C.md", "c")
      put!(u, v, "Workshop/D.md", "d")
      :ok
    end

    test "rename fetches only the rows under the folder, by the folder-reference index", ctx do
      %{user: u, vault: v} = ctx
      {{:ok, 2}, reads} = notes_reads(fn -> Notes.rename_folder(u, v, "Work", "Job") end)

      # The notes come in by `folder_ref_id` (the folder rows name the subtree),
      # not by decrypting a folder envelope per distinct folder in the vault.
      [fetch] = Enum.filter(reads, &(&1 =~ ~r/"folder_ref_id" = ANY\(\$\d+\)/))
      {:ok, paths} = Notes.list_tree_notes(u, v)

      assert Enum.map(paths, & &1.path) |> Enum.sort() ==
               ["Home/C.md", "Job/A.md", "Job/Sub/B.md", "Workshop/D.md"]

      # A vault big enough that the plan reflects selectivity, not a tiny
      # table's cost ties (as NotesPathIndexPlanTest). Added after the rename:
      # their ciphertext is not real, and only the plan reads them.
      for _ <- 1..1000,
          do: insert(:note, user: u, vault: v, folder_ref_id: nil)

      plan = QueryPlan.generic_plan(fetch, analyze: ["notes"], bitmapscan: false)
      assert plan =~ "notes_folder_ref", plan
    end

    test "scan_folders returns the folder and its descendants only", %{user: u, vault: v} do
      {:ok, rows} = Notes.scan_folders(u, v, ["Work"])
      assert rows |> Enum.map(& &1.path) |> Enum.sort() == ["Work/A.md", "Work/Sub/B.md"]

      {:ok, rows} = Notes.scan_folders(u, v, ["Work/Sub", "Home"])
      assert rows |> Enum.map(& &1.path) |> Enum.sort() == ["Home/C.md", "Work/Sub/B.md"]
    end
  end
end
