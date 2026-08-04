defmodule Engram.Links.RewriterTest do
  use Engram.DataCase, async: true

  alias Engram.Links
  alias Engram.Links.{Parser, Rewriter}

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
end
