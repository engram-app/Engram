defmodule Engram.Links.ResolutionCharacterizationTest do
  @moduledoc """
  Characterization of what a user SEES from link resolution, pinned before
  the resolve-on-read rework (stop storing resolved targets on `note_links`).

  Every assertion goes through the public read API (`Links.links_for_note/2`,
  `Links.backlinks_for_note/3`) after draining the indexing queue, so these
  pin the settled state a user observes, not the stored columns or the jobs
  that maintain them. The rework must pass this file unchanged.
  """

  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Attachments
  alias Engram.Links
  alias Engram.Notes
  alias Engram.Workers.ExtractNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  # A note whose outgoing links are written, as production does via the
  # ExtractNoteLinks job its content enqueues.
  defp note!(user, vault, path, content \\ "# note") do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id, user_id: user.id})
    note
  end

  defp upload!(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes for " <> path)
      })

    att
  end

  defp settle!, do: Oban.drain_queue(queue: :indexing, with_scheduled: true)

  defp outgoing(user, note), do: Links.links_for_note(user, note.id)

  defp target_of(user, note) do
    assert [link] = outgoing(user, note)
    link
  end

  defp backlink_sources(user, note) do
    user |> Links.backlinks_for_note(note.id) |> Enum.map(& &1.source_note_id) |> Enum.sort()
  end

  describe "resolution rules" do
    test "a folder target matches the full path case-insensitively", %{user: user, vault: vault} do
      target = note!(user, vault, "Sub/Target.md")
      source = note!(user, vault, "Source.md", "See [[sub/target]].")

      link = target_of(user, source)
      assert link.target_note_id == target.id
      assert link.target_path == "Sub/Target.md"
      refute link.dangling
    end

    test "a bare target takes the shortest path, then lexicographic order", %{
      user: user,
      vault: vault
    } do
      _deep = note!(user, vault, "a/b/c/Dup.md")
      _b = note!(user, vault, "b/Dup.md")
      a = note!(user, vault, "a/Dup.md")
      source = note!(user, vault, "Source.md", "See [[Dup]].")

      assert target_of(user, source).target_note_id == a.id
      assert backlink_sources(user, a) == [source.id]
    end

    test "a folder target with an explicit .md suffix matches", %{user: user, vault: vault} do
      target = note!(user, vault, "x/Page.md")
      source = note!(user, vault, "Source.md", "See [[x/Page.md]].")

      assert target_of(user, source).target_note_id == target.id
    end

    test "a .canvas note resolves from an extensionless target", %{user: user, vault: vault} do
      board = note!(user, vault, "Board.canvas", "{}")
      source = note!(user, vault, "Source.md", "See [[Board]].")

      assert target_of(user, source).target_note_id == board.id
    end

    test "an image extension routes to the attachment, not a note", %{user: user, vault: vault} do
      att = upload!(user, vault, "pics/photo.png")
      source = note!(user, vault, "Source.md", "![[photo.png]]")

      link = target_of(user, source)
      assert link.target_attachment_id == att.id
      assert link.target_note_id == nil
      refute link.dangling
    end

    test "an unresolvable target is dangling and keeps its text", %{user: user, vault: vault} do
      source = note!(user, vault, "Source.md", "See [[Nowhere|alias]].")

      link = target_of(user, source)
      assert link.dangling
      assert link.target_text == "Nowhere"
      assert link.alias == "alias"
      assert link.target_path == nil
    end

    test "a folder target that matches no path is dangling", %{user: user, vault: vault} do
      _other = note!(user, vault, "a/Page.md")
      source = note!(user, vault, "Source.md", "See [[b/Page]].")

      assert target_of(user, source).dangling
    end
  end

  describe "creating notes" do
    test "creating the target binds a waiting link, both directions", %{user: user, vault: vault} do
      source = note!(user, vault, "Source.md", "See [[Later]].")
      assert target_of(user, source).dangling

      target = note!(user, vault, "x/Later.md")
      settle!()

      assert target_of(user, source).target_note_id == target.id
      assert backlink_sources(user, target) == [source.id]
    end

    test "a new shorter-path note takes the bare link over", %{user: user, vault: vault} do
      long = note!(user, vault, "deep/er/Hub.md")
      source = note!(user, vault, "Source.md", "See [[Hub]].")
      assert target_of(user, source).target_note_id == long.id

      short = note!(user, vault, "Hub.md")
      settle!()

      assert target_of(user, source).target_note_id == short.id
      assert backlink_sources(user, short) == [source.id]
      assert backlink_sources(user, long) == []
    end

    test "a new same-length note that sorts later does not take over", %{
      user: user,
      vault: vault
    } do
      first = note!(user, vault, "a/Hub.md")
      source = note!(user, vault, "Source.md", "See [[Hub]].")

      _later = note!(user, vault, "b/Hub.md")
      settle!()

      assert target_of(user, source).target_note_id == first.id
    end
  end

  describe "renaming" do
    test "renaming a note to the linked name binds the link", %{user: user, vault: vault} do
      source = note!(user, vault, "Source.md", "See [[Fresh]].")
      old = note!(user, vault, "Old.md")
      settle!()
      assert target_of(user, source).dangling

      {:ok, _} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
      settle!()

      link = target_of(user, source)
      assert link.target_note_id == old.id
      assert link.target_path == "Fresh.md"
      assert backlink_sources(user, old) == [source.id]
    end

    test "after a REST rename, target_path shows the new path", %{user: user, vault: vault} do
      target = note!(user, vault, "Topic.md")
      source = note!(user, vault, "Source.md", "See [[Topic]].")

      {:ok, _} = Notes.rename_note(user, vault, "Topic.md", "moved/Renamed.md")
      settle!()

      link = target_of(user, source)
      assert link.target_note_id == target.id
      assert link.target_path == "moved/Renamed.md"
      assert backlink_sources(user, target) == [source.id]
    end

    test "a folder rename keeps links on the moved notes", %{user: user, vault: vault} do
      target = note!(user, vault, "old/Inner.md")
      source = note!(user, vault, "Source.md", "See [[old/Inner]] and [[Inner]].")

      {:ok, _} = Notes.rename_folder(user, vault, "old", "new")
      settle!()

      links = outgoing(user, source)
      assert length(links) == 2

      for link <- links do
        assert link.target_note_id == target.id, "#{link.target_text} lost its target"
        assert link.target_path == "new/Inner.md"
      end

      assert backlink_sources(user, target) == [source.id, source.id]
    end
  end

  describe "deleting" do
    test "deleting the target makes the link dangling", %{user: user, vault: vault} do
      _target = note!(user, vault, "Gone.md")
      source = note!(user, vault, "Source.md", "See [[Gone]].")

      :ok = Notes.delete_note(user, vault, "Gone.md")
      settle!()

      link = target_of(user, source)
      assert link.dangling
      assert link.target_path == nil
    end

    test "deleting the winner hands the link to a same-name sibling", %{
      user: user,
      vault: vault
    } do
      short = note!(user, vault, "Dup.md")
      sibling = note!(user, vault, "b/Dup.md")
      source = note!(user, vault, "Source.md", "See [[Dup]].")
      assert target_of(user, source).target_note_id == short.id

      :ok = Notes.delete_note_by_id(user, vault, short.id)
      settle!()

      assert target_of(user, source).target_note_id == sibling.id
      assert backlink_sources(user, sibling) == [source.id]
    end

    test "a deleted source disappears from backlinks", %{user: user, vault: vault} do
      target = note!(user, vault, "Target.md")
      keep = note!(user, vault, "Keep.md", "See [[Target]].")
      _gone = note!(user, vault, "GoneSource.md", "See [[Target]].")

      :ok = Notes.delete_note(user, vault, "GoneSource.md")
      settle!()

      assert backlink_sources(user, target) == [keep.id]
    end
  end

  describe "restoring" do
    test "re-creating a deleted target at the same path binds the link again", %{
      user: user,
      vault: vault
    } do
      _target = note!(user, vault, "Back.md")
      source = note!(user, vault, "Source.md", "See [[Back]].")

      :ok = Notes.delete_note(user, vault, "Back.md")
      settle!()
      assert target_of(user, source).dangling

      # Byte-different content: an identical re-push inside the delete-wins
      # window is refused as a stale resurrection, by design.
      restored = note!(user, vault, "Back.md", "# back, rewritten")
      settle!()

      link = target_of(user, source)
      assert link.target_note_id == restored.id
      assert link.target_path == "Back.md"
      assert backlink_sources(user, restored) == [source.id]
    end
  end

  describe "attachments" do
    test "uploading a missing attachment binds the embed", %{user: user, vault: vault} do
      source = note!(user, vault, "Source.md", "![[late.png]]")
      assert target_of(user, source).dangling

      att = upload!(user, vault, "late.png")
      settle!()

      assert target_of(user, source).target_attachment_id == att.id
    end

    test "deleting an attachment makes the embed dangling", %{user: user, vault: vault} do
      _att = upload!(user, vault, "doomed.png")
      source = note!(user, vault, "Source.md", "![[doomed.png]]")

      :ok = Attachments.delete_attachment(user, vault, "doomed.png")
      settle!()

      assert target_of(user, source).dangling
    end
  end

  describe "isolation" do
    test "a same-named note in another vault never resolves or backlinks", %{
      user: user,
      vault: vault
    } do
      other_vault = insert(:vault, user: user)
      foreign = note!(user, other_vault, "Shared.md")
      source = note!(user, vault, "Source.md", "See [[Shared]].")
      settle!()

      assert target_of(user, source).dangling
      assert backlink_sources(user, foreign) == []

      local = note!(user, vault, "Shared.md")
      settle!()

      assert target_of(user, source).target_note_id == local.id
      assert backlink_sources(user, local) == [source.id]
      assert backlink_sources(user, foreign) == []
    end

    test "another user's same-named note never resolves", %{user: user, vault: vault} do
      {:ok, stranger} = Engram.Fixtures.user_with_dek_fixture()
      stranger_vault = insert(:vault, user: stranger)
      _theirs = note!(stranger, stranger_vault, "Secret.md")
      source = note!(user, vault, "Source.md", "See [[Secret]].")
      settle!()

      assert target_of(user, source).dangling
    end
  end
end
