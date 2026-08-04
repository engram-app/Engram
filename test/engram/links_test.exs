defmodule Engram.LinksTest do
  use Engram.DataCase, async: true

  alias Engram.Links
  alias Engram.Links.NoteLink

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  describe "basename_key/1" do
    test "lowercases and strips note extensions only" do
      assert Links.basename_key("Folder/My Note.md") == "my note"
      assert Links.basename_key("My Note") == "my note"
      assert Links.basename_key("Board.canvas") == "board"
      assert Links.basename_key("pics/Photo.PNG") == "photo.png"
    end
  end

  describe "replace_links/4 + resolve" do
    test "resolves exact path, case-insensitively", %{user: user, vault: vault} do
      target = Engram.Fixtures.insert_note!(user, vault, %{path: "Sub/Target.md"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      parsed = [
        %{target: "sub/target", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ]

      :ok = Links.replace_links(user, vault, source.id, parsed)

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert link.target_note_id == target.id
    end

    test "basename resolution picks the shortest path, lexicographic tiebreak", %{
      user: user,
      vault: vault
    } do
      _long = Engram.Fixtures.insert_note!(user, vault, %{path: "a/b/c/Dup.md"})
      short = Engram.Fixtures.insert_note!(user, vault, %{path: "a/Dup.md"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "Dup", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert link.target_note_id == short.id
    end

    test "unresolvable target stores a dangling edge with hmac + ciphertext", %{
      user: user,
      vault: vault
    } do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "Ghost", alias: "shown", anchor: "H", link_type: "wikilink", position: 7}
        ])

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert is_nil(link.target_note_id)
      assert is_nil(link.target_attachment_id)
      assert byte_size(link.target_basename_hmac) == 32
      # decrypts back
      [decrypted] = Links.links_for_note(user, source.id)
      assert %{target_text: "Ghost", alias: "shown", anchor: "H", dangling: true} = decrypted
    end

    test "embed with binary extension resolves to an attachment", %{user: user, vault: vault} do
      # insert an attachment with real path crypto — mirror Fixtures.insert_note!
      # (add Engram.Fixtures.insert_attachment!/3 if it does not exist; same
      # Envelope.encrypt + hmac_field pattern over the attachments schema)
      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "pics/image.png"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "image.png", alias: nil, anchor: nil, link_type: "embed", position: 0}
        ])

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert link.target_attachment_id == att.id
    end

    test "wikilink with binary extension also resolves to an attachment", %{
      user: user,
      vault: vault
    } do
      # Extension alone decides notes-vs-attachments; link_type does not gate
      # it. `[[image.png]]` is a plain wikilink in Obsidian, and it still
      # resolves to the attachment.
      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "pics/image.png"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "image.png", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert link.target_attachment_id == att.id
    end

    test "replace is idempotent — re-running replaces, never duplicates", %{
      user: user,
      vault: vault
    } do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
      parsed = [%{target: "X", alias: nil, anchor: nil, link_type: "wikilink", position: 0}]
      :ok = Links.replace_links(user, vault, source.id, parsed)
      :ok = Links.replace_links(user, vault, source.id, parsed)
      {:ok, links} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert length(links) == 1
    end

    test "empty parsed list clears all edges for the source", %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "X", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      :ok = Links.replace_links(user, vault, source.id, [])
      {:ok, []} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
    end
  end

  describe "bind_danglers_for_hmac/3" do
    test "binds a dangler when its target is created", %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "Later", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      target = Engram.Fixtures.insert_note!(user, vault, %{path: "deep/Later.md"})

      :ok =
        Links.bind_danglers_for_hmac(
          user,
          vault,
          Links.basename_hmac(user, Links.basename_key("deep/Later.md"))
        )

      {:ok, [link]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert link.target_note_id == target.id
    end

    test "a shorter-path newcomer steals the binding", %{user: user, vault: vault} do
      old = Engram.Fixtures.insert_note!(user, vault, %{path: "a/b/Win.md"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "Win", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      {:ok, [l0]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert l0.target_note_id == old.id

      new = Engram.Fixtures.insert_note!(user, vault, %{path: "Win.md"})
      :ok = Links.bind_danglers_for_hmac(user, vault, Links.basename_hmac(user, "win"))

      {:ok, [l1]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert l1.target_note_id == new.id
    end
  end

  describe "on_note_soft_deleted/2" do
    test "drops outgoing and flips incoming to dangling", %{user: user, vault: vault} do
      a = Engram.Fixtures.insert_note!(user, vault, %{path: "A.md"})
      b = Engram.Fixtures.insert_note!(user, vault, %{path: "B.md"})

      :ok =
        Links.replace_links(user, vault, a.id, [
          %{target: "B", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      :ok =
        Links.replace_links(user, vault, b.id, [
          %{target: "A", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      :ok = Links.on_note_soft_deleted(user.id, b.id)

      {:ok, links} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      # b's outgoing edge is gone; a's edge to b is dangling again
      assert [%{source_note_id: source_id, target_note_id: nil}] = links
      assert source_id == a.id
    end
  end

  describe "backlinks_for_note/2" do
    test "returns sources with decrypted path/title", %{user: user, vault: vault} do
      a = Engram.Fixtures.insert_note!(user, vault, %{path: "A.md", title: "Note A"})
      b = Engram.Fixtures.insert_note!(user, vault, %{path: "B.md"})

      :ok =
        Links.replace_links(user, vault, a.id, [
          %{target: "B", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      assert [%{source_note_id: sid, source_path: "A.md"}] = Links.backlinks_for_note(user, b.id)
      assert sid == a.id
    end
  end

  test "RLS: user B cannot see user A's links", %{user: user, vault: vault} do
    source = Engram.Fixtures.insert_note!(user, vault, %{path: "S.md"})

    :ok =
      Links.replace_links(user, vault, source.id, [
        %{target: "X", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])

    other = insert(:user)
    {:ok, links} = Repo.with_tenant(other.id, fn -> Repo.all(NoteLink) end)
    assert links == []
  end

  # Task 4 — every production write path that sets path_hmac must also set
  # basename_hmac, or links to notes/attachments created via that path
  # silently never resolve. See task-4-brief.md.
  describe "basename_hmac stamped by production write paths" do
    test "upsert_note stamps basename_hmac", %{user: user, vault: vault} do
      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "Deep/Cased NAME.md",
          "content" => "x",
          "mtime" => 1_000.0
        })

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected = Engram.Crypto.hmac_field(filter_key, "cased name")

      {:ok, [note]} = Repo.with_tenant(user.id, fn -> Repo.all(Engram.Notes.Note) end)
      assert note.basename_hmac == expected
    end

    test "rename_note recomputes basename_hmac for the new path", %{user: user, vault: vault} do
      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "Old/Name.md",
          "content" => "x",
          "mtime" => 1_000.0
        })

      {:ok, _} = Engram.Notes.rename_note(user, vault, "Old/Name.md", "New/Renamed.md")

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected = Engram.Crypto.hmac_field(filter_key, "renamed")

      {:ok, [live]} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(from(n in Engram.Notes.Note, where: is_nil(n.deleted_at)))
        end)

      assert live.basename_hmac == expected
    end

    test "batch_upsert_notes stamps basename_hmac", %{user: user, vault: vault} do
      {:ok, %{results: [%{status: :ok}]}} =
        Engram.Notes.batch_upsert_notes(user, vault, [
          %{"path" => "Batch/Cased NAME.md", "content" => "x", "mtime" => 1_000.0}
        ])

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected = Engram.Crypto.hmac_field(filter_key, "cased name")

      {:ok, [note]} = Repo.with_tenant(user.id, fn -> Repo.all(Engram.Notes.Note) end)
      assert note.basename_hmac == expected
    end

    test "upsert_attachment stamps basename_hmac", %{user: user, vault: vault} do
      {:ok, att} =
        Engram.Attachments.upsert_attachment(user, vault, %{
          "path" => "pics/Cased NAME.PNG",
          "content_base64" => Base.encode64("x")
        })

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected = Engram.Crypto.hmac_field(filter_key, "cased name.png")

      assert att.basename_hmac == expected
    end
  end
end
