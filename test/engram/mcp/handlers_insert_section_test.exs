defmodule Engram.MCP.HandlersInsertSectionTest do
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  @content "# N\n\n## Todo\n\na\n\n### Sub\n\ns\n\n## Done\n\nx\n"

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "N.md", "content" => @content, "mtime" => 1.0})

    %{user: user, vault: vault}
  end

  defp body(user, vault) do
    {:ok, note} = Notes.get_note(user, vault, "N.md")
    {:ok, content} = Notes.authoritative_content(user, note)
    content
  end

  defp insert_section(u, v, extra),
    do:
      Handlers.handle(
        "edit_note",
        u,
        v,
        Map.merge(%{"path" => "N.md", "mode" => "insert_section"}, extra)
      )

  test "position start puts the text directly under the heading", %{user: u, vault: v} do
    assert {:ok, _, %{"mode" => "insert_section", "heading" => "Todo", "replacements" => nil}} =
             insert_section(u, v, %{
               "heading" => "Todo",
               "content" => "- first",
               "position" => "start"
             })

    assert body(u, v) =~ "## Todo\n- first\n\na"
  end

  # Review Focus 1: nested subheadings
  test "position end lands after the subsections, before the next same-level heading", %{
    user: u,
    vault: v
  } do
    assert {:ok, _, _} =
             insert_section(u, v, %{
               "heading" => "Todo",
               "content" => "- last",
               "position" => "end"
             })

    assert body(u, v) =~ "### Sub\n\ns\n- last\n\n## Done"
  end

  # Review Focus 1: last section
  test "position end on the last section keeps the trailing newline", %{user: u, vault: v} do
    assert {:ok, _, _} = insert_section(u, v, %{"heading" => "Done", "content" => "y"})
    assert String.ends_with?(body(u, v), "## Done\n\nx\ny\n")
  end

  test "explicit null position means end", %{user: u, vault: v} do
    assert {:ok, _, _} =
             insert_section(u, v, %{"heading" => "Done", "content" => "y", "position" => nil})

    assert String.ends_with?(body(u, v), "x\ny\n")
  end

  test "a missing heading refuses and writes nothing", %{user: u, vault: v} do
    before = body(u, v)
    assert {:error, msg} = insert_section(u, v, %{"heading" => "Nope", "content" => "y"})
    assert msg =~ "Heading not found: ## Nope"
    assert body(u, v) == before
  end

  test "level picks the heading level, and is validated", %{user: u, vault: v} do
    assert {:ok, _, _} =
             insert_section(u, v, %{"heading" => "Sub", "level" => 3, "content" => "z"})

    assert body(u, v) =~ "### Sub\n\ns\nz\n"

    assert {:error, "level must be between 1 and 6"} =
             insert_section(u, v, %{"heading" => "Sub", "level" => 7, "content" => "z"})
  end

  test "bad position, blank content, missing heading and missing note are fixable", %{
    user: u,
    vault: v
  } do
    assert {:error, "position must be start or end"} =
             insert_section(u, v, %{"heading" => "Todo", "content" => "y", "position" => "middle"})

    assert {:error, "content is required for mode insert_section"} =
             insert_section(u, v, %{"heading" => "Todo", "content" => "  "})

    assert {:error, "heading is required for mode insert_section"} =
             insert_section(u, v, %{"content" => "y"})

    assert {:error, "Note not found: Gone.md"} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "Gone.md",
               "mode" => "insert_section",
               "heading" => "A",
               "content" => "y"
             })
  end

  test "text params are refused under insert_section; position is refused elsewhere", %{
    user: u,
    vault: v
  } do
    assert {:error, "find is only valid with mode replace_text"} =
             insert_section(u, v, %{"heading" => "Todo", "content" => "y", "find" => "a"})

    assert {:error, "position is only valid with mode insert_section"} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_section",
               "heading" => "Todo",
               "content" => "z",
               "position" => "end"
             })

    # strict-mode nulls are not strays
    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "x",
               "replace" => "w",
               "position" => nil
             })
  end

  test "schema declares the mode and position" do
    {:ok, tool} = Engram.MCP.Tools.get("edit_note")
    props = tool.inputSchema["properties"]
    assert "insert_section" in props["mode"]["enum"]
    assert props["position"]["enum"] == ["start", "end"]
  end
end
