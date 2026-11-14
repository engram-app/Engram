defmodule Engram.Links.QualifiedWriterTest do
  # Every `note_links` writer sets `qualified` (S4.6, Engram#2523). There is
  # ONE writer of rows, `Links.replace_links_basenames/4` (ExtractNoteLinks
  # and the rename rewrite's `Rewriter.finish/4` both go through it); DEK
  # rotation and the link-key backfill only update other columns of a row
  # whose target text does not change. A row the previous release wrote
  # (NULL) is rewritten by the next extraction of its note even when its
  # links did not change.
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Notes
  alias Engram.Workers.ExtractNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  @content "[[Bare]] [[Folder/Pathed]] ![[img.png]] [x](../Up.md) [y](Plain.md)"

  defp qualified_by_position(note_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT position, qualified FROM note_links WHERE source_note_id = $1 ORDER BY position",
        [Ecto.UUID.dump!(note_id)]
      )

    Enum.map(rows, &List.last/1)
  end

  test "replace_links stores qualified per link", %{user: user, vault: vault} do
    source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
    :ok = Links.replace_links(user, vault, source.id, Parser.extract(@content))

    assert qualified_by_position(source.id) == [false, true, false, true, false]
  end

  test "an unchanged re-extraction heals a row the previous release left NULL", %{
    user: user,
    vault: vault
  } do
    source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
    parsed = Parser.extract(@content)
    :ok = Links.replace_links(user, vault, source.id, parsed)

    Repo.query!("UPDATE note_links SET qualified = NULL WHERE source_note_id = $1", [
      Ecto.UUID.dump!(source.id)
    ])

    :ok = Links.replace_links(user, vault, source.id, parsed)

    assert qualified_by_position(source.id) == [false, true, false, true, false]
  end

  test "ExtractNoteLinks (the note-write path) sets qualified", %{user: user, vault: vault} do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => @content}, actor: "api")

    assert :ok = perform_job(ExtractNoteLinks, %{"note_id" => note.id, "user_id" => user.id})
    assert qualified_by_position(note.id) == [false, true, false, true, false]
  end
end
