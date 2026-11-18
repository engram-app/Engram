defmodule Engram.Notes.LocationLatchTest do
  # A vault holding a folder moved without a cascade (S5) reads names
  # whatever `Location.on?/0` says. Before the latch, names off (the
  # `name_reads` kill switch, or a reopened / version-bumped `note_name`
  # ledger) made every lookup read stored paths: the moved note's stored
  # path is its OLD one, so a write at its shown path minted a second live
  # note on the same folder row with the same name, and once names came back
  # two notes were shown at one path.
  use Engram.DataCase, async: false

  alias Engram.{FolderRows, Notes, ServiceConfig}
  alias Engram.Notes.Location

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    on_exit(fn -> Engram.Cache.clear_local(:note_name) end)
    %{user: user, vault: vault}
  end

  defp names!(on?) do
    ServiceConfig.put_override(:name_reads, on?)
    assert Location.on?() == on?
  end

  defp live_count(vault) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*)::int FROM notes WHERE vault_id = $1 AND kind = 'note' " <>
          "AND deleted_at IS NULL",
        [Ecto.UUID.dump!(vault.id)]
      )

    n
  end

  test "names off in a moved vault: a write at the shown path updates the moved note",
       %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "A/x.md", "content" => "old"}, actor: "api")
    FolderRows.move_uncascaded!(u, FolderRows.tree(u)["A"].id, "B")

    names!(false)

    {:ok, written} =
      Notes.upsert_note(u, v, %{"path" => "B/x.md", "content" => "new"}, actor: "api")

    assert written.id == note.id
    assert live_count(v) == 1

    names!(true)
    {:ok, shown} = Notes.list_notes_in_folder(u, v, "B")
    assert [%{id: id, path: "B/x.md"}] = shown
    assert id == note.id
  end

  test "names off in a moved vault: the moved note is still at its shown path",
       %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "A/x.md", "content" => "x"}, actor: "api")
    FolderRows.move_uncascaded!(u, FolderRows.tree(u)["A"].id, "B")
    names!(false)

    assert {:ok, %{id: id, path: "B/x.md"}} = Notes.get_note(u, v, "B/x.md")
    assert id == note.id
    assert {:error, :not_found} = Notes.get_note(u, v, "A/x.md")
  end

  # Review H1 on #2648: during a `note_name` refill (or after a
  # previous-release rename) a moved row's name stamp is stale, so it is
  # shown at its stored (old) path. The lookup must find it there too, or a
  # write at the shown path mints a second live note.
  test "a moved row with a stale name stamp is found where it is shown", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "A/x.md", "content" => "old"}, actor: "api")
    FolderRows.move_uncascaded!(u, FolderRows.tree(u)["A"].id, "B")
    Repo.query!("UPDATE notes SET name_stamp = NULL WHERE id = $1", [Ecto.UUID.dump!(note.id)])

    {:ok, written} =
      Notes.upsert_note(u, v, %{"path" => "A/x.md", "content" => "new"}, actor: "api")

    assert written.id == note.id
    assert live_count(v) == 1
    assert {:ok, %{id: id}} = Notes.get_note(u, v, "A/x.md")
    assert id == note.id
  end
end
