defmodule Engram.Links.RewriterTest do
  # async: false — some tests below start a real :global-registered CrdtDoc
  # room (CrdtRegistry.ensure_started/3), which is the same sandbox hazard
  # documented in Engram.DataCase.setup_sandbox/1 (#777): a room is a
  # sandbox-using process not linked to the test, and only non-async mode
  # synchronously stops live rooms before the sandbox owner tears down.
  use Engram.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Links
  alias Engram.Links.{Parser, Rewriter}
  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, Note}
  alias Yex.Sync.SharedDoc

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp note_target(renamed, old_path, new_path, collision?) do
    %{
      kind: :note,
      id: renamed.id,
      old_path: old_path,
      new_path: new_path,
      old_basename_hmac: nil,
      collision?: collision?
    }
  end

  describe "plan_edits/5 — semantics matrix" do
    test "bare / aliased / anchored / embed all rewrite only the target segment", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Fresh.md"})
      full = "a [[Old]] b ![[Old|shown]] c [[Old#H1|x]] d"

      edits =
        Rewriter.plan_edits(
          user,
          vault,
          full,
          full,
          note_target(renamed, "Old.md", "Fresh.md", false)
        )

      assert length(edits) == 3
      assert Enum.all?(edits, &(&1.new == "Fresh"))
      assert Enum.all?(edits, &(binary_part(full, &1.rel_start, &1.len) == "Old"))

      assert Rewriter.splice(full, edits) ==
               "a [[Fresh]] b ![[Fresh|shown]] c [[Fresh#H1|x]] d"
    end

    test "code fences and inline code are skipped by construction", %{user: user, vault: vault} do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Fresh.md"})
      full = "[[Old]]\n```\n[[Old]]\n```\nand `[[Old]]` end"

      edits =
        Rewriter.plan_edits(
          user,
          vault,
          full,
          full,
          note_target(renamed, "Old.md", "Fresh.md", false)
        )

      assert length(edits) == 1
      assert Rewriter.splice(full, edits) == "[[Fresh]]\n```\n[[Old]]\n```\nand `[[Old]]` end"
    end

    test "path-qualified occurrence stays path-qualified with the new vault-relative path", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "new/Fresh.md"})
      full = "see [[sub/Old]]"

      edits =
        Rewriter.plan_edits(
          user,
          vault,
          full,
          full,
          note_target(renamed, "sub/Old.md", "new/Fresh.md", false)
        )

      assert Rewriter.splice(full, edits) == "see [[new/Fresh]]"
    end

    test "ambiguity forces path qualification of a bare occurrence", %{user: user, vault: vault} do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "new/Dup.md"})
      full = "see [[Old]]"

      edits =
        Rewriter.plan_edits(
          user,
          vault,
          full,
          full,
          note_target(renamed, "Old.md", "new/Dup.md", true)
        )

      assert Rewriter.splice(full, edits) == "see [[new/Dup]]"
    end

    test "casing follows the new file's actual name; explicit .md form is preserved", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "FRESH Note.md"})
      full = "[[old]] and [[Old.md]]"

      edits =
        Rewriter.plan_edits(
          user,
          vault,
          full,
          full,
          note_target(renamed, "Old.md", "FRESH Note.md", false)
        )

      assert Rewriter.splice(full, edits) == "[[FRESH Note]] and [[FRESH Note.md]]"
    end

    test "already-matching text is a no-op (idempotent)", %{user: user, vault: vault} do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Fresh.md"})
      full = "see [[Fresh]]"

      assert Rewriter.plan_edits(
               user,
               vault,
               full,
               full,
               note_target(renamed, "Fresh.md", "Fresh.md", false)
             ) ==
               []
    end

    test "occurrence that resolved to a sibling is NOT rewritten", %{user: user, vault: vault} do
      # Shorter-path sibling wins the pre-rename tiebreak for bare [[Dup]].
      _sibling = Engram.Fixtures.insert_note!(user, vault, %{path: "Dup.md"})
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Renamed.md"})
      full = "see [[Dup]]"

      assert Rewriter.plan_edits(
               user,
               vault,
               full,
               full,
               note_target(renamed, "x/Dup.md", "Renamed.md", false)
             ) ==
               []
    end

    test "attachment rename keeps the extension in the link text", %{user: user, vault: vault} do
      renamed = Engram.Fixtures.insert_attachment!(user, vault, %{path: "img/new.png"})
      full = "![[old.png]]"

      target = %{
        kind: :attachment,
        id: renamed.id,
        old_path: "img/old.png",
        new_path: "img/new.png",
        old_basename_hmac: nil,
        collision?: false
      }

      edits = Rewriter.plan_edits(user, vault, full, full, target)
      assert Rewriter.splice(full, edits) == "![[new.png]]"
    end

    test "invalid UTF-8 content goes through the parser's scrub gate without crashing", %{
      user: user,
      vault: vault
    } do
      renamed = Engram.Fixtures.insert_note!(user, vault, %{path: "Fresh.md"})
      full = "bad " <> <<0xFF>> <> " [[Old]]"
      scrubbed = Engram.Notes.Helpers.scrub_utf8(full, :write)

      edits =
        Rewriter.plan_edits(
          user,
          vault,
          scrubbed,
          scrubbed,
          note_target(renamed, "Old.md", "Fresh.md", false)
        )

      assert [%{old: "Old", new: "Fresh"}] = Enum.map(edits, &Map.take(&1, [:old, :new]))
    end
  end

  defp raw_note!(user, id) do
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get(Note, id) end)
    raw
  end

  describe "rewrite_source_note/5" do
    test "rewrites the doc via a tail-log Y-update and re-extracts edges", %{
      user: user,
      vault: vault
    } do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})

      content = "See [[Old]] and ![[Old|x]]."

      {:ok, source} =
        Notes.upsert_note(user, vault, %{"path" => "Source.md", "content" => content})

      :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))

      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")
      assert {:ok, :rewritten} = Rewriter.rewrite_source_note(user, vault, source.id, target)

      {:ok, text} = Notes.authoritative_content(user, raw_note!(user, source.id))
      assert text == "See [[Fresh]] and ![[Fresh|x]]."

      # Edges re-extracted: both now bind to the renamed note under its new text.
      links = Links.links_for_note(user, source.id)
      assert Enum.map(links, & &1.target_text) == ["Fresh", "Fresh"]
      assert Enum.all?(links, &(&1.target_note_id == renamed.id))
    end

    test "second run is a no-op (idempotent)", %{user: user, vault: vault} do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
      {:ok, source} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "[[Old]]"})
      :ok = Links.replace_links(user, vault, source.id, Parser.extract("[[Old]]"))

      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")
      assert {:ok, :rewritten} = Rewriter.rewrite_source_note(user, vault, source.id, target)
      assert {:ok, :noop} = Rewriter.rewrite_source_note(user, vault, source.id, target)
    end

    test "missing / deleted source note is skipped", %{user: user, vault: vault} do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")

      assert {:ok, :skipped} =
               Rewriter.rewrite_source_note(user, vault, Ecto.UUID.generate(), target)
    end

    test "head advancing between load and append triggers a bounded retry that converges", %{
      user: user,
      vault: vault
    } do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})

      {:ok, source} =
        Notes.upsert_note(user, vault, %{"path" => "R.md", "content" => "keep [[Old]]"})

      :ok = Links.replace_links(user, vault, source.id, Parser.extract("keep [[Old]]"))
      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")

      # Simulate a client edit landing in the race window exactly once:
      # append a real tail update (an insert at offset 0) built from the
      # note's current durable state.
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      before_persist = fn ->
        if Agent.get_and_update(agent, fn n -> {n, n + 1} end) == 0 do
          raw = raw_note!(user, source.id)
          {:ok, snapshot} = Engram.Crypto.decrypt_crdt_state(raw, user)
          {:ok, doc} = Engram.Notes.CrdtBridge.doc_from_state(snapshot)

          {:ok, _} =
            Repo.with_tenant(user.id, fn ->
              Engram.Notes.CrdtPersistence.replay_tail(doc, user, source.id)
            end)

          sv = Yex.encode_state_vector!(doc)
          text = Yex.Doc.get_text(doc, Engram.Notes.CrdtBridge.text_name())
          Yex.Text.insert(text, 0, "EDIT ")
          delta = Yex.encode_state_as_update!(doc, sv)

          _ =
            Engram.Notes.CrdtPersistence.update_v1(
              %{user_id: user.id, vault_id: vault.id, note_id: source.id},
              delta,
              nil,
              doc
            )
        end

        :ok
      end

      assert {:ok, :rewritten} =
               Rewriter.rewrite_source_note(user, vault, source.id, target,
                 before_persist: before_persist
               )

      {:ok, text} = Notes.authoritative_content(user, raw_note!(user, source.id))
      # BOTH survive: the concurrent client edit and the rewrite.
      assert text == "EDIT keep [[Fresh]]"
    end

    test "a head that advances on every attempt exhausts the retry budget", %{
      user: user,
      vault: vault
    } do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
      {:ok, source} = Notes.upsert_note(user, vault, %{"path" => "R2.md", "content" => "[[Old]]"})
      :ok = Links.replace_links(user, vault, source.id, Parser.extract("[[Old]]"))
      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")

      always_advance = fn ->
        {:ok, _} =
          Repo.with_tenant(user.id, fn ->
            %Engram.Notes.CrdtUpdateLog{}
            |> Engram.Notes.CrdtUpdateLog.changeset(%{
              note_id: source.id,
              user_id: user.id,
              vault_id: vault.id,
              update_ciphertext: <<0>>,
              update_nonce: <<0>>
            })
            |> Repo.insert()
          end)

        :ok
      end

      assert {:error, :head_advanced} =
               Rewriter.rewrite_source_note(user, vault, source.id, target,
                 before_persist: always_advance
               )
    end

    test "legacy row (no CRDT state) rewrites through upsert_note", %{user: user, vault: vault} do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
      # A fixture-inserted note has content but NO crdt_state and NO tail.
      legacy = Engram.Fixtures.insert_note!(user, vault, %{path: "L.md", content: "see [[Old]]"})
      :ok = Links.replace_links(user, vault, legacy.id, Parser.extract("see [[Old]]"))

      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")
      assert {:ok, :rewritten} = Rewriter.rewrite_source_note(user, vault, legacy.id, target)

      {:ok, note} = Notes.get_note(user, vault, "L.md")
      assert note.content == "see [[Fresh]]"
    end
  end

  describe "build_target/5" do
    test "derives new_path and collision from the live row", %{user: user, vault: vault} do
      {:ok, renamed} =
        Notes.upsert_note(user, vault, %{"path" => "sub/Fresh.md", "content" => "x"})

      {:ok, _dup} =
        Notes.upsert_note(user, vault, %{"path" => "other/Fresh.md", "content" => "y"})

      assert {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")
      assert target.new_path == "sub/Fresh.md"
      assert target.collision?
      assert is_binary(target.old_basename_hmac)
    end

    test "gone target row errors", %{user: user, vault: vault} do
      assert {:error, :target_gone} =
               Rewriter.build_target(user, vault, :note, Ecto.UUID.generate(), "Old.md")
    end

    test "attachment kind resolves via current_path/4's attachment clause", %{
      user: user,
      vault: vault
    } do
      attachment = Engram.Fixtures.insert_attachment!(user, vault, %{path: "img/new.png"})

      assert {:ok, target} =
               Rewriter.build_target(user, vault, :attachment, attachment.id, "img/old.png")

      assert target.new_path == "img/new.png"
    end
  end

  describe "rewrite_source_note/5 — UTF-16 offset correctness" do
    test "an astral codepoint before the link converges via UTF-16 units, not codepoints", %{
      user: user,
      vault: vault
    } do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})

      # 😀 (U+1F600) is one codepoint but TWO UTF-16 code units. If utf16_len/1
      # were swapped for a codepoint count (String.length/1), the computed
      # offset into the doc's Y.Text would land one unit short and corrupt
      # the rewrite instead of landing exactly on "Old".
      content = "😀 see [[Old]]"

      {:ok, source} =
        Notes.upsert_note(user, vault, %{"path" => "Emoji.md", "content" => content})

      :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))

      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")
      assert {:ok, :rewritten} = Rewriter.rewrite_source_note(user, vault, source.id, target)

      {:ok, text} = Notes.authoritative_content(user, raw_note!(user, source.id))
      assert text == "😀 see [[Fresh]]"
    end
  end

  describe "rewrite_source_note/5 — live room persistence" do
    test "a live room applies the delta via SharedDoc.update_doc/2 and converges", %{
      user: user,
      vault: vault
    } do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})

      {:ok, source} =
        Notes.upsert_note(user, vault, %{"path" => "Room.md", "content" => "[[Old]]"})

      :ok = Links.replace_links(user, vault, source.id, Parser.extract("[[Old]]"))
      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")

      {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, source.id)
      Sandbox.allow(Repo, self(), room)

      # Skips the unbind checkpoint (no post-test Repo write against a torn
      # down sandbox connection) — see CrdtRegistry.terminate_room/1.
      on_exit(fn -> CrdtRegistry.terminate_room(source.id) end)

      assert {:ok, :rewritten} = Rewriter.rewrite_source_note(user, vault, source.id, target)

      # The room's OWN doc converged — proves the live-room branch ran
      # (SharedDoc.update_doc/2), not a roomless fallback that happened to
      # also succeed.
      room_doc = SharedDoc.get_doc(room)
      assert CrdtBridge.project_doc(room_doc) == "[[Fresh]]"

      {:ok, text} = Notes.authoritative_content(user, raw_note!(user, source.id))
      assert text == "[[Fresh]]"
    end

    test "a room that dies between lookup and the update call falls through to the roomless path",
         %{user: user, vault: vault} do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})

      {:ok, source} =
        Notes.upsert_note(user, vault, %{"path" => "Gone.md", "content" => "[[Old]]"})

      :ok = Links.replace_links(user, vault, source.id, Parser.extract("[[Old]]"))
      {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")

      # Register a pid that is genuinely ALIVE at lookup time (so
      # CrdtRegistry.lookup/1 resolves it exactly like a real room) but exits
      # the instant it receives the SharedDoc.update_doc/2 call — the same
      # race as a room dying between lookup and the call landing, without
      # depending on :global's own (racy, timing-dependent) dead-pid cleanup.
      room =
        spawn(fn ->
          receive do
            _ -> exit(:simulated_room_death)
          end
        end)

      :yes = :global.register_name({:crdt_doc, source.id}, room)
      on_exit(fn -> :global.unregister_name({:crdt_doc, source.id}) end)
      assert CrdtRegistry.lookup(source.id) == room

      assert {:ok, :rewritten} = Rewriter.rewrite_source_note(user, vault, source.id, target)

      {:ok, text} = Notes.authoritative_content(user, raw_note!(user, source.id))
      assert text == "[[Fresh]]"
    end
  end

  describe "rewrite_for_note_rename/4 — end-to-end walk" do
    test "rewrites every referring note found via source_note_ids/5's hmac lookup", %{
      user: user,
      vault: vault
    } do
      {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
      {:ok, s1} = Notes.upsert_note(user, vault, %{"path" => "S1.md", "content" => "[[Old]]"})

      {:ok, s2} =
        Notes.upsert_note(user, vault, %{"path" => "S2.md", "content" => "see [[Old]] too"})

      :ok = Links.replace_links(user, vault, s1.id, Parser.extract("[[Old]]"))
      :ok = Links.replace_links(user, vault, s2.id, Parser.extract("see [[Old]] too"))

      assert :ok = Rewriter.rewrite_for_note_rename(user, vault, renamed.id, "Old.md")

      {:ok, t1} = Notes.authoritative_content(user, raw_note!(user, s1.id))
      {:ok, t2} = Notes.authoritative_content(user, raw_note!(user, s2.id))
      assert t1 == "[[Fresh]]"
      assert t2 == "see [[Fresh]] too"
    end
  end

  describe "rewrite_for_attachment_rename/4" do
    test "rewrites an embed target via build_target/5's attachment clause", %{
      user: user,
      vault: vault
    } do
      attachment = Engram.Fixtures.insert_attachment!(user, vault, %{path: "img/new.png"})

      {:ok, source} =
        Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "![[old.png]]"})

      :ok = Links.replace_links(user, vault, source.id, Parser.extract("![[old.png]]"))

      assert :ok =
               Rewriter.rewrite_for_attachment_rename(user, vault, attachment.id, "img/old.png")

      {:ok, text} = Notes.authoritative_content(user, raw_note!(user, source.id))
      assert text == "![[new.png]]"
    end
  end
end
