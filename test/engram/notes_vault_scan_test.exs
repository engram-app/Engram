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
  end

  describe "folder cascade" do
    setup %{user: u, vault: v} do
      put!(u, v, "Work/A.md", "a")
      put!(u, v, "Work/Sub/B.md", "b")
      put!(u, v, "Home/C.md", "c")
      put!(u, v, "Workshop/D.md", "d")
      :ok
    end

    test "rename fetches only the rows under the folder, by the folder index", ctx do
      %{user: u, vault: v} = ctx
      {{:ok, 2}, reads} = notes_reads(fn -> Notes.rename_folder(u, v, "Work", "Job") end)

      [fetch] = Enum.filter(reads, &(&1 =~ ~r/"folder_hmac" = ANY\(\$\d+\)/))
      {:ok, paths} = Notes.list_tree_notes(u, v)

      assert Enum.map(paths, & &1.path) |> Enum.sort() ==
               ["Home/C.md", "Job/A.md", "Job/Sub/B.md", "Workshop/D.md"]

      # A vault big enough that the plan reflects selectivity, not a tiny
      # table's cost ties (as NotesPathIndexPlanTest). Added after the rename:
      # their ciphertext is not real, and only the plan reads them.
      for _ <- 1..1000,
          do: insert(:note, user: u, vault: v, folder_hmac: :crypto.strong_rand_bytes(32))

      plan = QueryPlan.generic_plan(fetch, analyze: ["notes"], bitmapscan: false)
      assert plan =~ "notes_user_id_vault_id_folder_hmac_index", plan
    end

    test "scan_folders returns the folder and its descendants only", %{user: u, vault: v} do
      {:ok, rows} = Notes.scan_folders(u, v, ["Work"])
      assert rows |> Enum.map(& &1.path) |> Enum.sort() == ["Work/A.md", "Work/Sub/B.md"]

      {:ok, rows} = Notes.scan_folders(u, v, ["Work/Sub", "Home"])
      assert rows |> Enum.map(& &1.path) |> Enum.sort() == ["Home/C.md", "Work/Sub/B.md"]
    end
  end
end
