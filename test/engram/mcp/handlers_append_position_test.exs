defmodule Engram.MCP.HandlersAppendPositionTest do
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put!(u, v, path, content),
    do:
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => path, "content" => content, "mtime" => 1.0})

  defp body(u, v, path) do
    {:ok, note} = Notes.get_note(u, v, path)
    {:ok, c} = Notes.authoritative_content(u, note)
    c
  end

  test "start inserts after the frontmatter fence, frontmatter untouched", %{user: u, vault: v} do
    put!(u, v, "F.md", "---\ntags: [a]\n---\n# F\n\nold\n")
    # The storage pipeline canonicalizes YAML on write (flow -> block style);
    # that happens on the initial put! above, before our code runs. Capture
    # the ACTUAL stored frontmatter as the baseline instead of assuming the
    # original flow-style text survives, so this test only pins what
    # append_to_note itself must not touch: the frontmatter bytes.
    before = body(u, v, "F.md")
    {frontmatter, _rest} = Engram.Notes.Frontmatter.split(before)

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "F.md",
               "text" => "new",
               "position" => "start"
             })

    assert body(u, v, "F.md") == "---\n" <> frontmatter <> "---\nnew\n# F\n\nold\n"
  end

  test "start with no frontmatter goes to the very top", %{user: u, vault: v} do
    put!(u, v, "P.md", "# P\n\nold\n")

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "P.md",
               "text" => "new",
               "position" => "start"
             })

    assert body(u, v, "P.md") =~ ~r/\Anew\n# P/
  end

  test "start on an empty note becomes the body", %{user: u, vault: v} do
    put!(u, v, "Z.md", "")

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "Z.md",
               "text" => "new",
               "position" => "start"
             })

    assert body(u, v, "Z.md") == "new\n"
  end

  test "default position is still end", %{user: u, vault: v} do
    put!(u, v, "E.md", "# E\n\nold\n")

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{"path" => "E.md", "text" => "new"})

    assert body(u, v, "E.md") =~ ~r/old\nnew\z/
  end

  test "explicit null position behaves as end", %{user: u, vault: v} do
    put!(u, v, "N.md", "# N\n\nold\n")

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "N.md",
               "text" => "new",
               "position" => nil
             })

    assert body(u, v, "N.md") =~ ~r/old\nnew\z/
  end

  test "an unknown position is a fixable error", %{user: u, vault: v} do
    put!(u, v, "X.md", "x")

    assert {:error, msg} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "X.md",
               "text" => "t",
               "position" => "middle"
             })

    assert msg =~ "position must be end or start"
  end

  test "a non-string position is a fixable error", %{user: u, vault: v} do
    put!(u, v, "Y.md", "y")

    assert {:error, msg} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => "Y.md",
               "text" => "t",
               "position" => 1
             })

    assert msg =~ "position must be end or start"
  end
end
