defmodule Engram.Folders.RootRowReadTest do
  # S6 step 1a (Engram#2523): readers take a reference to the vault's root
  # folder row (`Rows.root_id/1`, written from step 1b on) as the root, the
  # same as a NULL reference. A rolling deploy and a rollback run 1a beside
  # 1b, so a vault holds both kinds at once and every reader must answer as
  # if all of them were NULL.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, FolderRows, Notes, QueryPlan, QueryRecorder, ServiceConfig}
  alias Engram.Folders.{Rows, Wire}
  alias Engram.Insights.{Snapshot, VaultDailyMetric}
  alias Engram.Notes.Location

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    old = put!(user, vault, "old.md")
    new = put!(user, vault, "new.md")
    put!(user, vault, "A/a.md")
    root = FolderRows.insert_root!(user, vault, [new.id])
    # `old` as a previous-release writer leaves it, whatever this one wrote.
    Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [Ecto.UUID.dump!(old.id)])
    %{user: user, vault: vault, old: old, new: new, root: root}
  end

  defp put!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "x", "mtime" => 1.0},
        actor: "api"
      )

    note
  end

  test "the fixture is step 1b's shape: one root note at the row, one at none", ctx do
    assert ctx.root == ctx.vault.id
    assert FolderRows.row(ctx.root).parent_id == nil
    assert FolderRows.ref("notes", ctx.new.id) == ctx.root
    assert FolderRows.ref("notes", ctx.old.id) == nil
  end

  test "the root page lists notes at the root row and at no row", %{user: u, vault: v} do
    {:ok, %{notes: notes, next_cursor: nil}} = Notes.list_notes_in_folder_page(u, v, "")
    assert notes |> Enum.map(& &1.path) |> Enum.sort() == ["new.md", "old.md"]

    # Paged one at a time: the two arms merge in id order, nothing twice.
    {:ok, %{notes: [first], next_cursor: c}} = Notes.list_notes_in_folder_page(u, v, "", limit: 1)

    {:ok, %{notes: [second], next_cursor: nil}} =
      Notes.list_notes_in_folder_page(u, v, "", limit: 1, cursor: c)

    assert Enum.sort([first.path, second.path]) == ["new.md", "old.md"]
  end

  # Audit gap: the two keyset arms merged over several pages. Root notes
  # alternate between the arms in id order, so every page of 3 takes rows
  # from both, and a cursor that skipped or repeated one arm's rows shows.
  test "the root page keyset pages across both arms with no gap or repeat", ctx do
    %{user: u, vault: v, old: old, new: new} = ctx
    more = for i <- 1..8, do: put!(u, v, "r#{i}.md")
    by_id = Enum.sort_by([old, new | more], & &1.id)
    {at_row, at_none} = by_id |> Enum.with_index() |> Enum.split_with(&(rem(elem(&1, 1), 2) == 0))
    FolderRows.insert_root!(u, v, Enum.map(at_row, &elem(&1, 0).id))
    set_null!(Enum.map(at_none, &elem(&1, 0).id))

    pages = pages!(u, v, 3)
    assert length(pages) == 4
    assert Enum.all?(pages, &(length(&1) <= 3))
    ids = Enum.concat(pages)
    assert ids == Enum.map(by_id, & &1.id)
    assert ids == Enum.uniq(ids)
    # Stable: the same walk again gives the same pages.
    assert pages!(u, v, 3) == pages
  end

  # Rollback window: release E (step 1b) wrote the root row and pointed root
  # notes at it, then the fleet rolled back to 0.89.0, which writes NULL root
  # references. The writes go through this branch's code, then the root
  # notes are set to 0.89.0's shape (NULL) by SQL, so the test stays true
  # once 1b's writer is underneath it. Release D's reads must take both.
  test "a rollback to 0.89.0 writes beside root-row references; D reads both", ctx do
    %{user: u, vault: v, old: old, new: new} = ctx
    late = put!(u, v, "late.md")
    {:ok, _} = Notes.rename_note(u, v, "new.md", "A/new.md")
    {:ok, a} = Notes.rename_note(u, v, "A/a.md", "a.md")
    set_null!([late.id, a.id])
    kept = put!(u, v, "kept.md")
    FolderRows.insert_root!(u, v, [kept.id])

    assert FolderRows.ref("notes", kept.id) == v.id
    assert FolderRows.ref("notes", new.id) not in [nil, v.id]

    {:ok, %{notes: notes, next_cursor: nil}} = Notes.list_notes_in_folder_page(u, v, "")
    assert notes |> Enum.map(& &1.path) |> Enum.sort() == ["a.md", "kept.md", "late.md", "old.md"]
    assert old.id in Enum.map(notes, & &1.id)
    {:ok, a} = Notes.list_notes_in_folder(u, v, "A")
    assert Enum.map(a, & &1.path) == ["A/new.md"]
    {:ok, counts} = Notes.list_folders_with_counts(u, v)
    assert Map.new(counts, &{&1.folder, &1.count}) == %{"" => 4, "A" => 1}
    assert {:ok, ["A"]} = Notes.list_folders_implied_by_notes(u, v)
  end

  defp set_null!(ids),
    do:
      Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = ANY($1)", [
        Enum.map(ids, &Ecto.UUID.dump!/1)
      ])

  defp pages!(u, v, limit, cursor \\ nil, acc \\ []) do
    {:ok, %{notes: notes, next_cursor: next}} =
      Notes.list_notes_in_folder_page(u, v, "", limit: limit, cursor: cursor)

    # A page is sorted by title (`list_notes_in_folder_page/4`); the keyset
    # is the id, so each page is an id range.
    acc = [notes |> Enum.map(& &1.id) |> Enum.sort() | acc]
    if next, do: pages!(u, v, limit, next, acc), else: Enum.reverse(acc)
  end

  test "folder counts give the root both kinds, once", %{user: u, vault: v} do
    {:ok, counts} = Notes.list_folders_with_counts(u, v)
    assert Map.new(counts, &{&1.folder, &1.count}) == %{"" => 2, "A" => 1}
  end

  test "the root is no implied folder", %{user: u, vault: v} do
    assert {:ok, ["A"]} = Notes.list_folders_implied_by_notes(u, v)
  end

  test "listings show no root folder and give root notes no folder id", ctx do
    %{user: u, vault: v, new: new} = ctx
    {:ok, dek} = Crypto.get_dek(u)
    rows = Repo.with_tenant!(u.id, fn -> Rows.live_rows(v.id) end)

    {[placed], folders} = Location.place([%{path: "new.md"}], rows, dek)
    assert placed.folder_id == nil
    assert Enum.map(folders, & &1.name) == ["A"]

    note = Repo.with_tenant!(u.id, fn -> Repo.get!(Engram.Notes.Note, new.id) end)
    assert Location.wire_fields(%{note | path: "new.md"}, true).folder_id == nil
  end

  test "the create reply gives a root note no folder id", %{user: u, vault: v, new: new} do
    ServiceConfig.put_override(:folder_ops, true)
    note = Repo.with_tenant!(u.id, fn -> Repo.get!(Engram.Notes.Note, new.id) end)
    reply = Repo.with_tenant!(u.id, fn -> Wire.create_reply(u, v, %{note | path: "new.md"}) end)
    assert %{folder_id: nil, folders: _} = reply
  end

  test "the canary takes a root-row reference as the root" do
    assert Engram.Bookkeeping.Canary.run().drift.folder_ref == 0
  end

  test "the daily snapshot counts the root once", %{vault: v} do
    day = Date.add(Date.utc_today(), -1)
    Snapshot.run(day: day)
    assert Repo.get_by!(VaultDailyMetric, vault_id: v.id, date: day).folders == 2
  end

  # The new arm is the folder page's own shape (`folder_ref_id = $n`, id
  # order, LIMIT) on a folder reference index: never a walk of the vault.
  test "the root-row arm reads the folder reference index under RLS", %{user: u, vault: v} do
    {_, queries} = QueryRecorder.record(fn -> Notes.list_notes_in_folder_page(u, v, "") end)
    me = self()

    [{sql, params}] =
      for %{sql: s, params: p, pid: ^me} <- queries,
          s =~ ~r/"folder_ref_id" = \$\d+/ and s =~ "LIMIT",
          do: {s, p}

    # A prod-shaped vault, added after the read (their ciphertext is not
    # real; only the plan reads them): 50 folders of 20 notes, and 20 at the
    # root row. A planner that walked the vault in id order would read the
    # folders' notes to fill a root page.
    folders = for _ <- 1..50, do: FolderRows.insert!(u, v, :crypto.strong_rand_bytes(32))
    refs = [Rows.root_id(v.id) | folders]

    Engram.Fixtures.insert_notes!(
      u,
      v,
      for(ref <- refs, _ <- 1..20, do: build(:note, folder_ref_id: ref))
    )

    QueryPlan.fresh!("notes")

    for {kind, plan} <- QueryPlan.rls_plans(u.id, sql, params) do
      assert plan =~ ~r/(using|Scan on) notes_folder_ref(_live|_live_id)? /, "#{kind}:\n#{plan}"
      refute plan =~ "Seq Scan on notes", "#{kind}:\n#{plan}"
    end
  end
end
