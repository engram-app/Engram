defmodule Engram.Links.ResolutionCharacterizationTest do
  @moduledoc """
  Characterization of what a user SEES from link resolution, pinned before
  the resolve-on-read rework (stop storing resolved targets on `note_links`,
  drop `RebindNoteLinks`). The rework must pass this file unchanged.

  ## Rules every test follows

  * **Writes go through production entry points** (`Notes`, `Attachments`,
    CRDT genesis) and `settle!/0` drains the indexing queue the way
    production would eventually run it, including jobs enqueued by jobs.
    Each note's own jobs are drained when it is written, so a later
    `settle!/0` never re-extracts an unrelated source note. Re-extraction
    is the mechanism that would mask a missing target-side update.
  * **Reads go through the public read surface only**: `links_for_note/2`,
    `backlinks_for_note/3`, MCP `get_notes`. Never the stored columns.
  * **Every lifecycle test reads BEFORE the change and again after it.** A
    resolve-on-read design caches per vault; a test that only reads after
    the change is green against a cache that never invalidates.

  "Same as before" means the settled state, after queues drain. Today a
  read can be stale until `RebindNoteLinks` runs; that window is not pinned.
  """

  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.RlsCase

  alias Engram.Attachments
  alias Engram.Crypto.UserDekRotation
  alias Engram.Links
  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp settle!,
    do: Oban.drain_queue(queue: :indexing, with_scheduled: true, with_recursion: true)

  # Writes a note and drains ITS jobs (link extraction included), so nothing
  # of this note is left queued for a later `settle!/0` to replay.
  defp note!(user, vault, path, content \\ "# note") do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    settle!()
    note
  end

  defp upload!(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes for " <> path)
      })

    settle!()
    att
  end

  defp outgoing(user, note), do: Links.links_for_note(user, note.id)

  defp target_of(user, note) do
    assert [link] = outgoing(user, note)
    link
  end

  # Backlink source ids in the order the API returns them.
  defp backlink_sources(user, note),
    do: user |> Links.backlinks_for_note(note.id) |> Enum.map(& &1.source_note_id)

  # ── resolution rules ─────────────────────────────────────────────────────

  describe "resolution rules" do
    test "a folder target matches the full path case-insensitively", %{user: user, vault: vault} do
      target = note!(user, vault, "Sub/Target.md")
      source = note!(user, vault, "Source.md", "See [[sub/target]].")

      link = target_of(user, source)
      assert link.target_note_id == target.id
      assert link.target_path == "Sub/Target.md"
      refute link.dangling
    end

    test "a bare target takes the shortest path", %{user: user, vault: vault} do
      _deep = note!(user, vault, "a/b/c/Dup.md")
      short = note!(user, vault, "zz/Dup.md")
      source = note!(user, vault, "Source.md", "See [[Dup]].")

      assert target_of(user, source).target_note_id == short.id
      assert backlink_sources(user, short) == [source.id]
    end

    test "equal-length paths break the tie lexicographically, not by creation order", %{
      user: user,
      vault: vault
    } do
      # Created later but sorts first: insertion order would pick `b/`.
      _b = note!(user, vault, "b/Tie.md")
      a = note!(user, vault, "a/Tie.md")
      source = note!(user, vault, "Source.md", "See [[Tie]].")

      assert target_of(user, source).target_note_id == a.id
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

    test "an image extension routes to the attachment even when a same-named note exists", %{
      user: user,
      vault: vault
    } do
      _decoy = note!(user, vault, "photo.png.md")
      att = upload!(user, vault, "pics/photo.png")
      source = note!(user, vault, "Source.md", "![[photo.png]]")

      link = target_of(user, source)
      assert link.target_attachment_id == att.id
      assert link.target_note_id == nil
      refute link.dangling
    end

    test "a dotted note name falls back from attachments to notes", %{user: user, vault: vault} do
      source = note!(user, vault, "Source.md", "See [[Node.js]].")
      assert target_of(user, source).dangling

      node = note!(user, vault, "Node.js.md")
      settle!()

      assert target_of(user, source).target_note_id == node.id
    end

    # Folder markers carry no basename key, so today they cannot match a link
    # at all; the `kind == "note"` filter is defence in depth. This pins the
    # user-visible outcome, whichever mechanism provides it.
    test "a folder never becomes a link target", %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "Hub")
      source = note!(user, vault, "Source.md", "See [[Hub]].")
      assert target_of(user, source).dangling

      hub = note!(user, vault, "deep/Hub.md")
      settle!()

      assert target_of(user, source).target_note_id == hub.id
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

    test "links in code are not links; a self-link resolves to itself", %{
      user: user,
      vault: vault
    } do
      _t = note!(user, vault, "T.md")

      source =
        note!(user, vault, "Source.md", "[[Source]]\n```\n[[T]]\n```\n`[[T]]`")

      link = target_of(user, source)
      assert link.target_note_id == source.id
      assert backlink_sources(user, source) == [source.id]
    end
  end

  # ── what each read returns ───────────────────────────────────────────────

  describe "read shapes" do
    test "outgoing links carry every field, in source order", %{user: user, vault: vault} do
      t = note!(user, vault, "T.md", "# T")
      att = upload!(user, vault, "img.png")

      source =
        note!(
          user,
          vault,
          "Source.md",
          "![[img.png]] [[T#Heading|Alias]] [label](T.md) ![[T]] [[Ghost]]"
        )

      assert outgoing(user, source) == [
               %{
                 target_text: "img.png",
                 alias: nil,
                 anchor: nil,
                 link_type: "embed",
                 target_note_id: nil,
                 target_attachment_id: att.id,
                 target_path: nil,
                 dangling: false
               },
               %{
                 target_text: "T",
                 alias: "Alias",
                 anchor: "Heading",
                 link_type: "wikilink",
                 target_note_id: t.id,
                 target_attachment_id: nil,
                 target_path: "T.md",
                 dangling: false
               },
               %{
                 target_text: "T.md",
                 alias: "label",
                 anchor: nil,
                 link_type: "wikilink",
                 target_note_id: t.id,
                 target_attachment_id: nil,
                 target_path: "T.md",
                 dangling: false
               },
               %{
                 target_text: "T",
                 alias: nil,
                 anchor: nil,
                 link_type: "embed",
                 target_note_id: t.id,
                 target_attachment_id: nil,
                 target_path: "T.md",
                 dangling: false
               },
               %{
                 target_text: "Ghost",
                 alias: nil,
                 anchor: nil,
                 link_type: "wikilink",
                 target_note_id: nil,
                 target_attachment_id: nil,
                 target_path: nil,
                 dangling: true
               }
             ]
    end

    test "backlinks carry source path, title, alias and anchor, one row per edge", %{
      user: user,
      vault: vault
    } do
      t = note!(user, vault, "T.md", "# T")
      source = note!(user, vault, "Source.md", "# Src Title\n[[T#Heading|Alias]] [label](T.md)")

      assert Links.backlinks_for_note(user, t.id) == [
               %{
                 source_note_id: source.id,
                 source_path: "Source.md",
                 source_title: "Src Title",
                 alias: "Alias",
                 anchor: "Heading"
               },
               %{
                 source_note_id: source.id,
                 source_path: "Source.md",
                 source_title: "Src Title",
                 alias: "label",
                 anchor: nil
               }
             ]
    end

    test "backlinks are ordered by link position, not by source path", %{
      user: user,
      vault: vault
    } do
      t = note!(user, vault, "T.md")
      late = note!(user, vault, "A.md", "[[x]] [[y]] [[T]]")
      early = note!(user, vault, "Z.md", "[[T]]")

      assert backlink_sources(user, t) == [early.id, late.id]
    end

    test "backlinks honour the limit and distinct_sources options", %{user: user, vault: vault} do
      t = note!(user, vault, "T.md")
      a = note!(user, vault, "A.md", "[[T]] [[T]]")
      _b = note!(user, vault, "B.md", "[[x]] [[y]] [[T]]")

      assert length(Links.backlinks_for_note(user, t.id)) == 3
      assert [%{source_note_id: first}] = Links.backlinks_for_note(user, t.id, limit: 1)
      assert first == a.id

      assert user
             |> Links.backlinks_for_note(t.id, distinct_sources: true)
             |> Enum.map(& &1.source_path)
             |> Enum.sort() == ["A.md", "B.md"]
    end

    test "reads return rows under the production role (tenant-scoped)", %{
      user: user,
      vault: vault
    } do
      t = note!(user, vault, "T.md")
      source = note!(user, vault, "Source.md", "[[T]]")

      assert {:returned, [%{target_note_id: tid}]} =
               as_prod_role(fn -> Links.links_for_note(user, source.id) end)

      assert tid == t.id

      assert {:returned, [%{source_note_id: sid}]} =
               as_prod_role(fn -> Links.backlinks_for_note(user, t.id) end)

      assert sid == source.id
    end
  end

  # ── lifecycle: every test reads before and after the change ──────────────

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
      assert backlink_sources(user, long) == [source.id]

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
      assert target_of(user, source).target_note_id == first.id

      later = note!(user, vault, "b/Hub.md")
      settle!()

      assert target_of(user, source).target_note_id == first.id
      assert backlink_sources(user, later) == []
    end
  end

  describe "renaming" do
    test "renaming a note to the linked name binds the link", %{user: user, vault: vault} do
      source = note!(user, vault, "Source.md", "See [[Fresh]].")
      old = note!(user, vault, "Old.md")
      assert target_of(user, source).dangling
      assert backlink_sources(user, old) == []

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
      assert target_of(user, source).target_path == "Topic.md"
      assert backlink_sources(user, target) == [source.id]

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

      assert Enum.map(outgoing(user, source), & &1.target_path) == [
               "old/Inner.md",
               "old/Inner.md"
             ]

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
      refute target_of(user, source).dangling

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
      assert backlink_sources(user, sibling) == []

      :ok = Notes.delete_note_by_id(user, vault, short.id)
      settle!()

      assert target_of(user, source).target_note_id == sibling.id
      assert backlink_sources(user, sibling) == [source.id]
    end

    test "a deleted source disappears from backlinks", %{user: user, vault: vault} do
      target = note!(user, vault, "Target.md")
      keep = note!(user, vault, "Keep.md", "See [[Target]].")
      gone = note!(user, vault, "GoneSource.md", "See [[Target]].")
      assert Enum.sort(backlink_sources(user, target)) == Enum.sort([keep.id, gone.id])

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
      refute target_of(user, source).dangling

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
      att = upload!(user, vault, "doomed.png")
      source = note!(user, vault, "Source.md", "![[doomed.png]]")
      assert target_of(user, source).target_attachment_id == att.id

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

      assert target_of(user, source).dangling
    end
  end

  describe "DEK rotation" do
    # Rotation re-encrypts every vault name the user owns, so this user's
    # only vault must be written under their DEK (the factory vault is not).
    test "links keep resolving and new notes still bind after a key rotation" do
      # Rotation scrolls Qdrant; stub it for THIS process only (a global
      # `:qdrant_url` put/delete leaks into other tests).
      bypass = Bypass.open()
      :ok = Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":{"points":[],"next_page_offset":null}}))
      end)

      {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
      vault = Engram.Fixtures.insert_vault!(user, "RotationVault")
      t = note!(user, vault, "T.md")
      source = note!(user, vault, "Source.md", "[[T]] [[Later]]")
      assert [%{target_note_id: tid}, %{dangling: true}] = outgoing(user, source)
      assert tid == t.id

      assert :ok = UserDekRotation.rotate_user(user.id)
      user = Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id))

      assert [%{target_note_id: ^tid}, %{dangling: true}] = outgoing(user, source)
      assert backlink_sources(user, t) == [source.id]

      later = note!(user, vault, "Later.md")
      settle!()

      assert [%{target_note_id: ^tid}, %{target_note_id: lid}] = outgoing(user, source)
      assert lid == later.id
      assert backlink_sources(user, later) == [source.id]
    end
  end

  # ── CRDT renames ─────────────────────────────────────────────────────────

  describe "CRDT renames" do
    # Obsidian rewrites links itself on rename, so the server must not. Until
    # the plugin's rewritten content arrives, a bare link falls through to
    # whatever the old name now resolves to.
    test "an Obsidian rename of the winner falls through to the sibling until the plugin rewrites",
         %{user: user, vault: vault} do
      short = note!(user, vault, "CrdtA.md")
      sibling = note!(user, vault, "b/CrdtA.md")
      source = note!(user, vault, "Source.md", "See [[CrdtA]].")
      assert target_of(user, source).target_note_id == short.id
      assert backlink_sources(user, sibling) == []

      assert {:ok, _} =
               Notes.genesis_crdt_note(user, vault, short.id, "CrdtZ.md", origin: "obsidian")

      settle!()

      assert target_of(user, source).target_note_id == sibling.id
      assert backlink_sources(user, sibling) == [source.id]
      assert backlink_sources(user, short) == []

      # The plugin's rewrite lands as ordinary content.
      _ = note!(user, vault, "Source.md", "See [[CrdtZ]].")

      link = target_of(user, source)
      assert link.target_note_id == short.id
      assert link.target_path == "CrdtZ.md"
      assert backlink_sources(user, short) == [source.id]
      assert backlink_sources(user, sibling) == []
    end

    test "an Obsidian rename with no sibling leaves the link dangling until the plugin rewrites",
         %{user: user, vault: vault} do
      target = note!(user, vault, "Solo.md")
      source = note!(user, vault, "Source.md", "See [[Solo]].")
      assert target_of(user, source).target_note_id == target.id

      assert {:ok, _} =
               Notes.genesis_crdt_note(user, vault, target.id, "Renamed.md", origin: "obsidian")

      settle!()
      assert target_of(user, source).dangling
      assert backlink_sources(user, target) == []

      _ = note!(user, vault, "Source.md", "See [[Renamed]].")

      assert target_of(user, source).target_note_id == target.id
      assert backlink_sources(user, target) == [source.id]
    end

    test "an Obsidian folder move keeps bare links and drops stale folder links",
         %{user: user, vault: vault} do
      inner = note!(user, vault, "old/Inner.md")
      source = note!(user, vault, "Source.md", "See [[Inner]] and [[old/Inner]].")
      assert Enum.map(outgoing(user, source), & &1.target_note_id) == [inner.id, inner.id]

      assert {:ok, _} =
               Notes.genesis_crdt_note(user, vault, inner.id, "new/Inner.md", origin: "obsidian")

      settle!()

      assert [bare, folder] = outgoing(user, source)
      assert bare.target_note_id == inner.id
      assert bare.target_path == "new/Inner.md"
      assert folder.dangling
      assert backlink_sources(user, inner) == [source.id]
    end

    test "a web-app rename rewrites the link and keeps it on the moved note",
         %{user: user, vault: vault} do
      short = note!(user, vault, "WebA.md")
      sibling = note!(user, vault, "b/WebA.md")
      source = note!(user, vault, "Source.md", "See [[WebA]].")
      assert target_of(user, source).target_note_id == short.id

      assert {:ok, _} = Notes.genesis_crdt_note(user, vault, short.id, "WebZ.md", origin: "web")
      settle!()

      link = target_of(user, source)
      assert link.target_note_id == short.id
      assert link.target_text == "WebZ"
      assert backlink_sources(user, short) == [source.id]
      assert backlink_sources(user, sibling) == []
    end
  end

  # ── MCP get_notes ────────────────────────────────────────────────────────

  describe "MCP get_notes" do
    defp mcp_links(user, vault, path) do
      assert {:ok, _text, %{"notes" => [n]}} =
               Handlers.handle("get_notes", user, vault, %{
                 "paths" => [path],
                 "include_links" => true
               })

      Map.take(n, ["backlinks", "outgoing", "unresolved", "links_truncated"])
    end

    test "attachment links are hidden; repeated targets are listed once", %{
      user: user,
      vault: vault
    } do
      _att = upload!(user, vault, "pic.png")
      _note = note!(user, vault, "Note.md")

      _source =
        note!(user, vault, "Source.md", "![[pic.png]] [[Note]] [[Note]] [[Ghost]] [[Ghost]]")

      assert mcp_links(user, vault, "Source.md") == %{
               "backlinks" => [],
               "outgoing" => ["Note.md"],
               "unresolved" => ["Ghost"],
               "links_truncated" => false
             }
    end

    test "backlinks follow a shorter-path takeover and drop deleted sources",
         %{user: user, vault: vault} do
      _long = note!(user, vault, "deep/Hub.md")
      _a = note!(user, vault, "A.md", "[[Hub]]")
      _b = note!(user, vault, "B.md", "[[Hub]]")
      assert Enum.sort(mcp_links(user, vault, "deep/Hub.md")["backlinks"]) == ["A.md", "B.md"]
      assert mcp_links(user, vault, "A.md")["outgoing"] == ["deep/Hub.md"]

      _short = note!(user, vault, "Hub.md")
      :ok = Notes.delete_note(user, vault, "B.md")
      settle!()

      assert mcp_links(user, vault, "Hub.md")["backlinks"] == ["A.md"]
      assert mcp_links(user, vault, "deep/Hub.md")["backlinks"] == []
      assert mcp_links(user, vault, "A.md")["outgoing"] == ["Hub.md"]
    end

    test "backlinks past the limit are truncated and flagged", %{user: user, vault: vault} do
      t = note!(user, vault, "T.md")
      _a = note!(user, vault, "A.md", "[[T]]")
      _b = note!(user, vault, "B.md", "[[T]]")

      assert {%{"backlinks" => [_one], "links_truncated" => true}, {true, 0, 0}} =
               Handlers.links_payload(user, t, 1)
    end
  end

  # ── read cost ────────────────────────────────────────────────────────────

  describe "read cost" do
    # Reads must not scale with the size of the vault. A resolve-on-read
    # design may pay for the candidates sharing a link's basename, but never
    # for unrelated notes. Measured as Repo queries issued by the caller.
    defp query_count(fun) do
      me = self()
      ref = make_ref()
      handler = {__MODULE__, ref}

      :telemetry.attach(
        handler,
        [:engram, :repo, :query],
        fn _e, _m, _meta, _c ->
          if self() == me, do: send(me, {ref, :q})
        end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

      count_msgs(ref, 0)
    end

    defp count_msgs(ref, n) do
      receive do
        {^ref, :q} -> count_msgs(ref, n + 1)
      after
        0 -> n
      end
    end

    defp read_both(user, source, target) do
      query_count(fn ->
        Links.links_for_note(user, source.id)
        Links.backlinks_for_note(user, target.id)
      end)
    end

    test "query count does not grow with unrelated notes", %{user: user, vault: vault} do
      t = note!(user, vault, "T.md")
      source = note!(user, vault, "Source.md", "[[T]] [[Ghost]]")
      _warm = read_both(user, source, t)
      small = read_both(user, source, t)

      for i <- 1..300, do: Engram.Fixtures.insert_note!(user, vault, %{path: "filler/n#{i}.md"})

      _warm = read_both(user, source, t)
      assert read_both(user, source, t) == small
    end

    test "query count does not grow with the number of links in the note", %{
      user: user,
      vault: vault
    } do
      for i <- 1..40, do: note!(user, vault, "t#{i}.md")
      t = note!(user, vault, "T.md")
      few = note!(user, vault, "Few.md", "[[T]] [[t1]]")
      many = note!(user, vault, "Many.md", Enum.map_join(1..40, " ", &"[[t#{&1}]]") <> " [[T]]")

      _warm = read_both(user, few, t)
      _warm = read_both(user, many, t)
      assert read_both(user, many, t) == read_both(user, few, t)
    end

    test "query count does not grow with the number of same-name candidates", %{
      user: user,
      vault: vault
    } do
      t = note!(user, vault, "index.md")
      source = note!(user, vault, "Source.md", "[[index]]")
      _warm = read_both(user, source, t)
      small = read_both(user, source, t)

      for i <- 1..300, do: Engram.Fixtures.insert_note!(user, vault, %{path: "f#{i}/index.md"})
      settle!()

      assert target_of(user, source).target_note_id == t.id
      _warm = read_both(user, source, t)
      assert read_both(user, source, t) == small
    end
  end
end
