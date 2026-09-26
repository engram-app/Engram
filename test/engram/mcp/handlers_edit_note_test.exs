defmodule Engram.MCP.HandlersEditNoteTest do
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "N.md",
        "content" => "# N\n\n## Todo\n\na\na\n\n## Done\n\nx\n",
        "mtime" => 1.0
      })

    %{user: user, vault: vault}
  end

  defp body(user, vault) do
    {:ok, note} = Notes.get_note(user, vault, "N.md")
    {:ok, content} = Notes.authoritative_content(user, note)
    content
  end

  test "replace_text replaces the first occurrence", %{user: u, vault: v} do
    assert {:ok, _, %{"replacements" => 1, "mode" => "replace_text"}} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "a",
               "replace" => "b"
             })

    assert body(u, v) =~ "## Todo\n\nb\na"
  end

  test "replace_text refuses when expected_replacements does not match, and writes nothing", %{
    user: u,
    vault: v
  } do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "a",
               "replace" => "b",
               "occurrence" => -1,
               "expected_replacements" => 1
             })

    assert msg =~ "expected 1 replacement(s), found 2"
    assert body(u, v) == before
  end

  test "replace_text accepts old_text/new_text aliases", %{user: u, vault: v} do
    assert {:ok, _, %{"replacements" => 1}} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "old_text" => "x",
               "new_text" => "y"
             })
  end

  test "replace_section replaces under the heading only", %{user: u, vault: v} do
    assert {:ok, _, %{"heading" => "Todo", "mode" => "replace_section"}} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_section",
               "heading" => "Todo",
               "content" => "z"
             })

    assert body(u, v) =~ "## Todo\nz\n## Done"
  end

  # Review Focus 1
  test "a parameter from the other mode is a fixable error, not a partial edit", %{
    user: u,
    vault: v
  } do
    before = body(u, v)

    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_text",
               "find" => "a",
               "replace" => "b",
               "heading" => "Todo"
             })

    assert msg =~ "heading is only valid with mode replace_section"
    assert body(u, v) == before
  end

  test "missing mode-required params are named", %{user: u, vault: v} do
    assert {:error, msg} =
             Handlers.handle("edit_note", u, v, %{
               "path" => "N.md",
               "mode" => "replace_section",
               "content" => "z"
             })

    assert msg =~ "heading is required for mode replace_section"
  end
end
