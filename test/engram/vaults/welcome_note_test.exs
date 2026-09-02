defmodule Engram.Vaults.WelcomeNoteTest do
  @moduledoc """
  The note seeded into every newly created vault. Content assertions are
  deliberately narrow — the prose is meant to be edited freely — but the parts
  the web app actually renders (frontmatter keys, the `created` date, the doc
  links) are pinned, because a typo there ships a broken first impression.
  """
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.Vaults.WelcomeNote

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  describe "seed/2" do
    test "writes the welcome note into the vault", %{user: user, vault: vault} do
      assert :ok = WelcomeNote.seed(user, vault)

      assert {:ok, note} = Notes.get_note(user, vault, WelcomeNote.path())
      assert note.path == "Welcome to Engram.md"
      assert note.content =~ "## Try these"
    end

    test "swallows a failed write so vault creation still succeeds", %{
      user: user,
      vault: vault
    } do
      # notes_cap 0 makes the write fail deterministically. A vault without its
      # sample note is recoverable; a 500 after the vault already committed is
      # the failure mode this rescue exists to prevent.
      insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 0})

      assert :ok = WelcomeNote.seed(user, vault)
      assert {:error, :not_found} = Notes.get_note(user, vault, WelcomeNote.path())
    end
  end

  describe "content/1" do
    test "stamps the given date into the created property" do
      content = WelcomeNote.content(~D[2026-01-15])

      assert content =~ "created: 2026-01-15"
    end

    test "opens with frontmatter the properties widget can parse" do
      lines = WelcomeNote.content(~D[2026-01-15]) |> String.split("\n")

      assert List.first(lines) == "---"
      assert Enum.any?(lines, &(&1 == "tags: [example]"))
      assert Enum.any?(lines, &(&1 == "done: false"))
    end

    test "links frontmatter and YAML at references that exist" do
      content = WelcomeNote.content(~D[2026-01-15])

      assert content =~ "https://obsidian.md/help/properties"
      assert content =~ "https://learnxinyminutes.com/yaml/"
      assert content =~ "https://engram.page/docs"
    end

    test "names all three view modes and the reading toggle" do
      content = WelcomeNote.content(~D[2026-01-15])

      # The kebab's own labels, verbatim — see `noteMenuActions/1` in
      # frontend/src/viewer/tree-actions/action-list.ts. A rename there without
      # one here ships a note describing a menu that no longer exists.
      for mode <- ["**Edit**", "**Raw**", "**Reading**"] do
        assert content =~ mode
      end

      assert content =~ "flips between editing and reading"
    end

    # The seeded file is a file the user edits, and the editor shows source
    # newlines as real breaks. A paragraph hard-wrapped at 80 columns therefore
    # arrives looking like it has stray line breaks in it — which is exactly
    # what it looked like. One line per paragraph; let the editor soft-wrap.
    test "never hard-wraps a paragraph across lines" do
      offenders =
        WelcomeNote.content(~D[2026-01-15])
        |> String.split("\n")
        # Drop the frontmatter block: its keys are one-per-line by definition,
        # not wrapped prose.
        |> Enum.drop_while(&(&1 != "---"))
        |> Enum.drop(1)
        |> Enum.drop_while(&(&1 != "---"))
        |> Enum.chunk_every(2, 1, [""])
        |> Enum.reduce({[], false}, fn [line, next], {bad, in_fence?} ->
          cond do
            String.starts_with?(line, "```") -> {bad, not in_fence?}
            in_fence? -> {bad, in_fence?}
            # Only prose lines: a table row, list item, callout, heading,
            # frontmatter fence or footnote definition may legitimately be
            # followed by another non-blank line.
            prose?(line) and prose?(next) -> {[line | bad], in_fence?}
            true -> {bad, in_fence?}
          end
        end)
        |> elem(0)

      assert offenders == []
    end

    test "carries no H1 — the inline title renders the filename as one" do
      refute WelcomeNote.content(~D[2026-01-15]) =~ ~r/^# /m
    end

    test "avoids markdown the web viewer does not render" do
      content = WelcomeNote.content(~D[2026-01-15])

      # Fold markers parse as a bullet list (@portaljs/remark-callouts does not
      # consume them) and ==highlight== / raw HTML are unsupported by design.
      # See frontend markdown-syntax.ts.
      refute content =~ ~r/^> \[!\w+\][-+]/m
      refute content =~ "=="
    end

    test "defaults to today" do
      assert WelcomeNote.content() =~ "created: #{Date.utc_today()}"
    end
  end

  # A continuation-capable prose line: not blank and not opening a block
  # construct that owns its own line.
  defp prose?(line) do
    trimmed = String.trim(line)

    trimmed != "" and
      not String.starts_with?(trimmed, ["|", "-", ">", "#", "[^", "---", "```", "*"])
  end
end
