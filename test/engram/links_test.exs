defmodule Engram.LinksTest do
  use Engram.DataCase, async: true

  import ExUnit.CaptureLog

  alias Engram.Links
  alias Engram.Links.NoteLink
  alias Engram.Links.Parser
  alias Engram.Notes

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

      assert [%{target_note_id: id, dangling: false}] = Links.links_for_note(user, source.id)
      assert id == target.id
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

      assert [%{target_note_id: id}] = Links.links_for_note(user, source.id)
      assert id == short.id
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
      assert byte_size(link.target_basename_hmac) == 32
      # decrypts back
      [decrypted] = Links.links_for_note(user, source.id)

      assert %{
               target_text: "Ghost",
               alias: "shown",
               anchor: "H",
               dangling: true,
               target_note_id: nil,
               target_attachment_id: nil
             } = decrypted
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

      assert [%{target_attachment_id: id}] = Links.links_for_note(user, source.id)
      assert id == att.id
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

      assert [%{target_attachment_id: id}] = Links.links_for_note(user, source.id)
      assert id == att.id
    end

    test "a dotted note name resolves as a note when no same-basename attachment exists", %{
      user: user,
      vault: vault
    } do
      # Path.extname("Node.js") == ".js" — extension-routing alone would send
      # this straight to the (empty) attachments table and never fall back.
      target = Engram.Fixtures.insert_note!(user, vault, %{path: "Node.js.md"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "Node.js", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      assert [%{target_note_id: id, target_attachment_id: nil}] =
               Links.links_for_note(user, source.id)

      assert id == target.id
    end

    test "image.png still resolves to the attachment, not a note, when both tables miss", %{
      user: user,
      vault: vault
    } do
      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "pics/image.png"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "image.png", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      assert [%{target_attachment_id: id, target_note_id: nil}] =
               Links.links_for_note(user, source.id)

      assert id == att.id
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

    test "replace_links called twice for the same note converges to the last parse",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "x"}, actor: "api")

      :ok = Links.replace_links(user, vault, note.id, Parser.extract("a [[One]] b [[Two]]"))
      :ok = Links.replace_links(user, vault, note.id, Parser.extract("a [[Three]]"))

      assert [%{target_text: "Three"}] = Links.links_for_note(user, note.id)
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

  describe "concurrent replace_links race (Task 2)" do
    # Task 2 — two writers (ExtractNoteLinks fast path + the embed pipeline's
    # commit_index, or duplicate bulk jobs) interleaving replace_links/4's
    # delete+insert under READ COMMITTED can violate
    # unique_index([:source_note_id, :position]): a second writer's DELETE
    # cannot see the first writer's uncommitted INSERT. Fix: serialize
    # per-source-note writes via `pg_advisory_xact_lock`, taken as the first
    # statement inside the existing transaction. Real cross-connection
    # concurrency is untestable under the Ecto sandbox (single shared
    # connection per test) — this source-string assertion is the accepted
    # substitute already used for the identical problem in
    # attachments_test.exs:88-98 (T3-audit H1).
    test "replace_links/4 takes a per-source-note advisory lock inside its transaction", %{
      user: user,
      vault: vault
    } do
      # Asserted on the executed statements: the lock, the DELETE and the
      # INSERT must share one transaction so the lock serializes the pair and
      # auto-releases on commit/rollback.
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      {:ok, queries} =
        Engram.QueryRecorder.record(fn ->
          Links.replace_links(user, vault, source.id, [
            %{target: "Elsewhere", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
          ])
        end)

      locked =
        queries
        |> Engram.QueryRecorder.transactions()
        |> Enum.filter(fn txn -> Enum.any?(txn, &(&1 =~ "pg_advisory_xact_lock")) end)

      assert [txn] = locked,
             "replace_links must take its advisory lock inside one transaction (Task 2)\n" <>
               Engram.QueryRecorder.format(queries)

      lock_at = Enum.find_index(txn, &(&1 =~ "pg_advisory_xact_lock"))
      delete_at = Enum.find_index(txn, &(&1 =~ ~r/^DELETE FROM "note_links"/))
      insert_at = Enum.find_index(txn, &(&1 =~ ~r/^INSERT INTO "note_links"/))

      assert delete_at && insert_at, "the delete+insert must run in the locked transaction"
      assert lock_at < delete_at and lock_at < insert_at, "the lock must precede the writes"
    end
  end

  describe "resolve on read" do
    test "a dangler resolves once its target is created", %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "Later", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      target = Engram.Fixtures.insert_note!(user, vault, %{path: "deep/Later.md"})

      assert [%{target_note_id: id}] = Links.links_for_note(user, source.id)
      assert id == target.id
    end

    test "a shorter-path newcomer steals the binding", %{user: user, vault: vault} do
      old = Engram.Fixtures.insert_note!(user, vault, %{path: "a/b/Win.md"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "Win", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      assert [%{target_note_id: id0}] = Links.links_for_note(user, source.id)
      assert id0 == old.id

      new = Engram.Fixtures.insert_note!(user, vault, %{path: "Win.md"})

      assert [%{target_note_id: id1}] = Links.links_for_note(user, source.id)
      assert id1 == new.id
    end

    # replace_links skips the rewrite when the stored edges equal the new
    # ones. A field that fails to decrypt must never compare equal to an
    # ABSENT field (nil), or a corrupt envelope survives every re-extraction.
    test "a corrupt alias is rewritten even when the new edge has no alias", %{
      user: user,
      vault: vault
    } do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Src.md"})
      edge = %{target: "T", alias: nil, anchor: nil, link_type: "wikilink", position: 0}

      :ok = Links.replace_links(user, vault, source.id, [%{edge | alias: "A"}])
      {:ok, [old]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)

      Repo.update_all(
        from(l in NoteLink, where: l.id == ^old.id),
        [set: [alias_ciphertext: <<0::128>>]],
        skip_tenant_check: true
      )

      capture_log(fn -> :ok = Links.replace_links(user, vault, source.id, [edge]) end)

      {:ok, [new]} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
      assert new.id != old.id
      assert is_nil(new.alias_ciphertext)
    end

    test "a corrupt edge reads as dangling and logged; other edges still resolve", %{
      user: user,
      vault: vault
    } do
      source1 = Engram.Fixtures.insert_note!(user, vault, %{path: "Corrupt1.md"})
      source2 = Engram.Fixtures.insert_note!(user, vault, %{path: "Healthy2.md"})

      :ok =
        Links.replace_links(user, vault, source1.id, [
          %{target: "Later", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      :ok =
        Links.replace_links(user, vault, source2.id, [
          %{target: "Later", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      {:ok, [edge1]} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(from(l in NoteLink, where: l.source_note_id == ^source1.id))
        end)

      # Overwrite the ciphertext with garbage — AES-GCM auth-tag verification
      # fails, so decrypt_field/7 returns nil (same shape as any at-rest
      # corruption), which used to crash `basename_key(nil)`.
      Repo.update_all(
        from(l in NoteLink, where: l.id == ^edge1.id),
        [set: [target_text_ciphertext: <<0::128>>]],
        skip_tenant_check: true
      )

      target = Engram.Fixtures.insert_note!(user, vault, %{path: "Later.md"})

      log =
        capture_log(fn ->
          # source2's healthy edge resolves; the corrupt one crashes nothing.
          [l2] = Links.links_for_note(user, source2.id)
          assert l2.target_note_id == target.id

          # Backlinks select by the key written with the edge, never decrypting
          # its text, so the corrupt edge still counts there.
          sources = user |> Links.backlinks_for_note(target.id) |> Enum.map(& &1.source_note_id)
          assert source2.id in sources

          assert [%{dangling: true, target_text: nil}] = Links.links_for_note(user, source1.id)
        end)

      assert log =~ "links_decrypt_failed"
    end
  end

  describe "on_note_soft_deleted/2" do
    test "drops outgoing edges", %{user: user, vault: vault} do
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
      # b's outgoing edge is gone; a's edge to b stays (b may come back)
      assert [%{source_note_id: source_id}] = links
      assert source_id == a.id
    end
  end

  describe "links_for_note/2 — decrypt failure logging" do
    test "a corrupt field logs a decrypt failure instead of failing silently", %{
      user: user,
      vault: vault
    } do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "SourceCorruptAlias.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "X", alias: "shown", anchor: nil, link_type: "wikilink", position: 0}
        ])

      {:ok, [edge]} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(from(l in NoteLink, where: l.source_note_id == ^source.id))
        end)

      Repo.update_all(
        from(l in NoteLink, where: l.id == ^edge.id),
        [set: [alias_ciphertext: <<0::128>>]],
        skip_tenant_check: true
      )

      log =
        capture_log(fn ->
          [link] = Links.links_for_note(user, source.id)
          assert is_nil(link.alias)
        end)

      assert log =~ "decrypt"
    end
  end

  describe "links_for_note/2, the passed user" do
    test "a struct without a DEK still decrypts (DEK provisioned after auth)", %{
      user: user,
      vault: vault
    } do
      _target = Engram.Fixtures.insert_note!(user, vault, %{path: "DekTarget.md"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "DekSource.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "DekTarget", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      stale = %{user | encrypted_dek: nil}
      assert [%{target_path: "DekTarget.md"}] = Links.links_for_note(stale, source.id)
    end
  end

  describe "backlinks_for_attachment/3" do
    test "returns notes that embed or link the attachment", %{user: user, vault: vault} do
      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "files/Report.zip"})
      a = Engram.Fixtures.insert_note!(user, vault, %{path: "A.md", title: "Note A"})
      b = Engram.Fixtures.insert_note!(user, vault, %{path: "B.md"})
      _other = Engram.Fixtures.insert_note!(user, vault, %{path: "C.md"})

      :ok =
        Links.replace_links(user, vault, a.id, [
          %{target: "Report.zip", alias: nil, anchor: nil, link_type: "embed", position: 0},
          %{target: "report.zip", alias: nil, anchor: nil, link_type: "wikilink", position: 1}
        ])

      :ok =
        Links.replace_links(user, vault, b.id, [
          %{
            target: "files/report.zip",
            alias: nil,
            anchor: nil,
            link_type: "wikilink",
            position: 0
          }
        ])

      sources =
        user |> Links.backlinks_for_attachment(vault.id, att.id) |> Enum.map(& &1.source_note_id)

      assert Enum.sort(sources) == Enum.sort([a.id, b.id])
    end

    test "finds a link written before the attachment existed", %{user: user, vault: vault} do
      a = Engram.Fixtures.insert_note!(user, vault, %{path: "A.md"})

      :ok =
        Links.replace_links(user, vault, a.id, [
          %{target: "later.pdf", alias: nil, anchor: nil, link_type: "embed", position: 0}
        ])

      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "later.pdf"})

      assert [%{source_note_id: sid, source_path: "A.md"}] =
               Links.backlinks_for_attachment(user, vault.id, att.id)

      assert sid == a.id
    end

    test "is empty for an unknown or note id", %{user: user, vault: vault} do
      note = Engram.Fixtures.insert_note!(user, vault, %{path: "A.md"})
      assert Links.backlinks_for_attachment(user, vault.id, Ecto.UUID.generate()) == []
      assert Links.backlinks_for_attachment(user, vault.id, note.id) == []
    end

    test "is empty when the attachment is in another vault", %{user: user, vault: vault} do
      other = insert(:vault, user: user)
      att = Engram.Fixtures.insert_attachment!(user, other, %{path: "x.pdf"})
      a = Engram.Fixtures.insert_note!(user, other, %{path: "A.md"})

      :ok =
        Links.replace_links(user, other, a.id, [
          %{target: "x.pdf", alias: nil, anchor: nil, link_type: "embed", position: 0}
        ])

      assert [_] = Links.backlinks_for_attachment(user, other.id, att.id)
      assert Links.backlinks_for_attachment(user, vault.id, att.id) == []
    end

    test "never reaches another user's or another vault's links on a shared name", %{
      user: user,
      vault: vault
    } do
      {:ok, intruder} = Engram.Fixtures.user_with_dek_fixture()
      theirs = insert(:vault, user: intruder)
      other = insert(:vault, user: user)

      link = fn owner, v, note_path ->
        n = Engram.Fixtures.insert_note!(owner, v, %{path: note_path})

        :ok =
          Links.replace_links(owner, v, n.id, [
            %{target: "shared.pdf", alias: nil, anchor: nil, link_type: "embed", position: 0}
          ])

        n
      end

      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "shared.pdf"})
      mine = link.(user, vault, "Mine.md")
      _same_user_other_vault = link.(user, other, "Elsewhere.md")
      _ = Engram.Fixtures.insert_attachment!(user, other, %{path: "shared.pdf"})

      their_att = Engram.Fixtures.insert_attachment!(intruder, theirs, %{path: "shared.pdf"})
      _ = link.(intruder, theirs, "Theirs.md")

      assert [%{source_note_id: id}] = Links.backlinks_for_attachment(user, vault.id, att.id)
      assert id == mine.id

      # Another user's attachment id, asked through this user's vault or theirs.
      assert Links.backlinks_for_attachment(user, vault.id, their_att.id) == []
      assert Links.backlinks_for_attachment(user, theirs.id, their_att.id) == []
      assert Links.backlinks_for_attachment(intruder, theirs.id, att.id) == []
      assert Links.backlinks_for_attachment(intruder, vault.id, att.id) == []
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

    # Finding #5 (PR #1229 review) — backlinks_for_note/2 is unbounded, a
    # heavily-linked note could return an arbitrarily large response. Fixed
    # with `@backlinks_limit 200` + `limit:` in the query. Driving 201 real
    # (encrypted) edges through the fixture pipeline just to exercise the
    # cap is too heavy for a unit test, so this pins the public constant
    # instead and covers ordering with a small, cheap edge count — the
    # `limit:` clause itself is a one-line addition verified by code review.
    test "backlinks_limit/0 is 200" do
      assert Links.backlinks_limit() == 200
    end

    # `opts[:limit]` lets a caller (get_notes' include_links) probe for
    # truncation with `limit: n + 1` without manufacturing 200+ real edges;
    # a plain call with no opts must stay byte-identical to before.
    test "opts[:limit] overrides the cap for a single call", %{user: user, vault: vault} do
      target = Engram.Fixtures.insert_note!(user, vault, %{path: "Target.md"})

      for n <- 1..3 do
        source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source#{n}.md"})

        :ok =
          Links.replace_links(user, vault, source.id, [
            %{target: "Target", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
          ])
      end

      assert length(Links.backlinks_for_note(user, target.id, limit: 2)) == 2
      assert length(Links.backlinks_for_note(user, target.id)) == 3
    end

    # A source note with several edges to the same target must count once,
    # not once per edge. This was the false-positive get_notes' truncation
    # probe hit before this option existed.
    test "opts[:distinct_sources] collapses one source's multiple edges to one row", %{
      user: user,
      vault: vault
    } do
      target = Engram.Fixtures.insert_note!(user, vault, %{path: "Target.md"})
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      :ok =
        Links.replace_links(user, vault, source.id, [
          %{target: "Target", alias: nil, anchor: nil, link_type: "wikilink", position: 0},
          %{target: "Target", alias: nil, anchor: nil, link_type: "wikilink", position: 1}
        ])

      assert length(Links.backlinks_for_note(user, target.id)) == 2

      assert [%{source_note_id: sid}] =
               Links.backlinks_for_note(user, target.id, distinct_sources: true)

      assert sid == source.id
    end

    test "opts[:distinct_sources] counts unique linking notes past duplicate edges", %{
      user: user,
      vault: vault
    } do
      target = Engram.Fixtures.insert_note!(user, vault, %{path: "Target.md"})

      dup_source = Engram.Fixtures.insert_note!(user, vault, %{path: "Dup.md"})

      :ok =
        Links.replace_links(user, vault, dup_source.id, [
          %{target: "Target", alias: nil, anchor: nil, link_type: "wikilink", position: 0},
          %{target: "Target", alias: nil, anchor: nil, link_type: "wikilink", position: 1}
        ])

      other = Engram.Fixtures.insert_note!(user, vault, %{path: "Other.md"})

      :ok =
        Links.replace_links(user, vault, other.id, [
          %{target: "Target", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])

      # 3 edges total from 2 unique sources. With limit: 2 (probing for "more
      # than 1 unique source"), the raw edge count would wrongly say 3 > 1;
      # distinct_sources correctly says 2 (not > 1).
      assert length(Links.backlinks_for_note(user, target.id)) == 3
      assert length(Links.backlinks_for_note(user, target.id, distinct_sources: true)) == 2

      assert length(Links.backlinks_for_note(user, target.id, limit: 1, distinct_sources: true)) ==
               1
    end

    test "multiple backlinks come back ordered by position, id", %{user: user, vault: vault} do
      target = Engram.Fixtures.insert_note!(user, vault, %{path: "Target.md"})

      sources =
        for n <- 1..3 do
          Engram.Fixtures.insert_note!(user, vault, %{path: "Source#{n}.md"})
        end

      Enum.each(sources, fn source ->
        :ok =
          Links.replace_links(user, vault, source.id, [
            %{target: "Target", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
          ])
      end)

      backlinks = Links.backlinks_for_note(user, target.id)
      assert length(backlinks) == 3

      assert Enum.map(backlinks, & &1.source_note_id) |> Enum.sort() ==
               Enum.map(sources, & &1.id) |> Enum.sort()
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
        Engram.Notes.upsert_note(
          user,
          vault,
          %{
            "path" => "Deep/Cased NAME.md",
            "content" => "x",
            "mtime" => 1_000.0
          },
          actor: "api"
        )

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected = Engram.Crypto.hmac_field(filter_key, "cased name")

      {:ok, [note]} = Repo.with_tenant(user.id, fn -> Repo.all(Engram.Notes.Note) end)
      assert note.basename_hmac == expected
    end

    test "rename_note recomputes basename_hmac for the new path", %{user: user, vault: vault} do
      {:ok, _} =
        Engram.Notes.upsert_note(
          user,
          vault,
          %{
            "path" => "Old/Name.md",
            "content" => "x",
            "mtime" => 1_000.0
          },
          actor: "api"
        )

      {:ok, _} = Engram.Notes.rename_note(user, vault, "Old/Name.md", "New/Renamed.md")

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected = Engram.Crypto.hmac_field(filter_key, "renamed")

      {:ok, [live]} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(from(n in Engram.Notes.Note, where: is_nil(n.deleted_at)))
        end)

      assert live.basename_hmac == expected
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

  describe "live_basename_count/3" do
    test "counts live notes and attachments sharing a basename key", %{user: user, vault: vault} do
      Engram.Fixtures.insert_note!(user, vault, %{path: "a/Dup.md"})
      Engram.Fixtures.insert_note!(user, vault, %{path: "b/Dup.md"})
      Engram.Fixtures.insert_attachment!(user, vault, %{path: "c/Dup.png"})

      assert Links.live_basename_count(user, vault, "dup") == 2
      assert Links.live_basename_count(user, vault, "dup.png") == 1
      assert Links.live_basename_count(user, vault, "ghost") == 0
    end
  end

  describe "pre_rename_winner?/6" do
    test "true when the renamed note at its old path wins the tiebreak", %{
      user: user,
      vault: vault
    } do
      _longer = Engram.Fixtures.insert_note!(user, vault, %{path: "deep/nested/Dup.md"})
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Renamed.md"})

      assert Links.pre_rename_winner?(user, vault, "Dup", :note, renamed.id, "Dup.md")
    end

    test "false when a shorter-path sibling won pre-rename", %{user: user, vault: vault} do
      _sibling = Engram.Fixtures.insert_note!(user, vault, %{path: "Dup.md"})
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Renamed.md"})

      refute Links.pre_rename_winner?(user, vault, "Dup", :note, renamed.id, "x/Dup.md")
    end

    test "false when the target basename differs from the old basename", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Renamed.md"})

      refute Links.pre_rename_winner?(user, vault, "Other", :note, renamed.id, "Dup.md")
    end

    test "path-qualified target must match the old path (case-insensitive)", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Renamed.md"})

      assert Links.pre_rename_winner?(user, vault, "sub/Dup", :note, renamed.id, "Sub/Dup.md")
      refute Links.pre_rename_winner?(user, vault, "other/Dup", :note, renamed.id, "Sub/Dup.md")
    end

    test "attachment kind: renamed attachment at old path wins for its extensioned target", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_attachment!(user, vault, %{path: "new/pic.png"})

      assert Links.pre_rename_winner?(
               user,
               vault,
               "pic.png",
               :attachment,
               renamed.id,
               "old/pic.png"
             )
    end
  end

  # Resolution moved from write to read, so the N+1 guard counts the
  # candidate queries of `links_for_note/2`.
  describe "links_for_note/2 candidate prefetch" do
    test "resolves every link with a bounded number of candidate queries",
         %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

      targets =
        for i <- 1..12 do
          Engram.Fixtures.insert_note!(user, vault, %{path: "Target#{i}.md"})
        end

      content = Enum.map_join(1..12, " ", &"[[Target#{&1}]]")
      parsed = Parser.extract(content)
      assert length(parsed) == 12

      :ok = Links.replace_links(user, vault, source.id, parsed)

      {count, edges} = count_candidate_queries(fn -> Links.links_for_note(user, source.id) end)

      # One prefetch per table, NOT one query per link. Before this was 12+.
      assert count <= 2, "expected <= 2 candidate queries for 12 links, got #{count}"

      # ...and the resolution is still correct for every edge.
      assert length(edges) == 12

      assert Enum.sort(Enum.map(edges, & &1.target_note_id)) ==
               Enum.sort(Enum.map(targets, & &1.id))
    end

    test "a dangling link still resolves to nil without extra queries",
         %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
      hit = Engram.Fixtures.insert_note!(user, vault, %{path: "Real.md"})
      parsed = Parser.extract("[[Real]] [[Nope]] [[AlsoMissing]]")

      :ok = Links.replace_links(user, vault, source.id, parsed)

      {count, edges} = count_candidate_queries(fn -> Links.links_for_note(user, source.id) end)

      assert count <= 2
      assert Enum.map(edges, & &1.target_note_id) == [hit.id, nil, nil]
      assert Enum.map(edges, & &1.dangling) == [false, true, true]
    end

    test "duplicate targets in one note share a single prefetched bucket",
         %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
      target = Engram.Fixtures.insert_note!(user, vault, %{path: "Same.md"})
      parsed = Parser.extract("[[Same]] [[Same]] [[Same]] [[Same]]")

      :ok = Links.replace_links(user, vault, source.id, parsed)

      {count, edges} = count_candidate_queries(fn -> Links.links_for_note(user, source.id) end)

      assert count <= 2
      assert length(edges) == 4
      assert Enum.all?(edges, &(&1.target_note_id == target.id))
    end
  end

  describe "replace_links/4 statement sizing" do
    @tag timeout: 120_000
    test "a note with more links than one statement can bind still persists all of them",
         %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "MOC.md"})

      # 5_000 edges x 17 binds = 85_000 parameters — past the protocol's 65535
      # cap. Every edge carries BOTH optional envelopes so the row hits its
      # widest column count; a version of this test without alias/anchor binds
      # only 13 per row and would pass against the unchunked insert.
      #
      # Pre-fix this did not fail the assertion below, it KILLED the pooled
      # connection ("Postgrex.Protocol disconnected: postgresql protocol can
      # not handle 85000 parameters"), so the failure mode to watch for on a
      # regression is a connection error, not a count mismatch.
      parsed =
        for i <- 0..4999 do
          %{
            target: "Target #{i}",
            alias: "alias #{i}",
            anchor: "anchor #{i}",
            link_type: "wikilink",
            position: i
          }
        end

      :ok = Links.replace_links(user, vault, source.id, parsed)

      {:ok, count} =
        Repo.with_tenant(user.id, fn ->
          Repo.aggregate(from(l in NoteLink, where: l.source_note_id == ^source.id), :count)
        end)

      assert count == 5_000
    end

    test "replacing links is still last-writer-wins across the chunk boundary",
         %{user: user, vault: vault} do
      source = Engram.Fixtures.insert_note!(user, vault, %{path: "MOC.md"})

      wide = for i <- 0..2_499, do: parsed_link("Target #{i}", i)
      :ok = Links.replace_links(user, vault, source.id, wide)

      # A chunked insert must not turn the delete+insert into a partial update:
      # the second call spans fewer chunks than the first, and every row from
      # the first must be gone.
      :ok = Links.replace_links(user, vault, source.id, [parsed_link("Only", 0)])

      {:ok, edges} =
        Repo.with_tenant(user.id, fn ->
          Repo.all(from(l in NoteLink, where: l.source_note_id == ^source.id))
        end)

      assert length(edges) == 1
    end
  end

  defp parsed_link(target, position) do
    %{target: target, alias: nil, anchor: nil, link_type: "wikilink", position: position}
  end

  # Counts SELECTs against the candidate tables (notes/attachments) issued on
  # this process while `fun` runs.
  defp count_candidate_queries(fun) do
    test_pid = self()
    handler_id = "candidate-query-counter-#{System.unique_integer([:positive])}"
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _event, _measurements, meta, _config ->
        query = meta[:query] || ""

        if self() == test_pid and meta[:source] in ["notes", "attachments"] and
             String.starts_with?(query, "SELECT") and String.contains?(query, "basename_hmac") do
          Agent.update(counter, &(&1 + 1))
        end
      end,
      nil
    )

    try do
      result = fun.()
      {Agent.get(counter, & &1), result}
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end
end
