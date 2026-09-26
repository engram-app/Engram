defmodule Engram.MCP.HandlersPartialReadTest do
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  @bt String.duplicate("`", 3)

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    content =
      "---\ntags: [a]\n# not a heading\n---\n# T\n\n## Todo\n\na\n\n#{@bt}\n## fake\n#{@bt}\n\n### Sub\n\ns\n\n## Done\n\nx\n"

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "P.md", "content" => content, "mtime" => 1.0})

    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "Q.md",
        "content" => "plain text",
        "mtime" => 1.0
      })

    %{user: user, vault: vault}
  end

  defp get(u, v, args), do: Handlers.handle("get_notes", u, v, args)

  # Review Focus 5
  test "section returns only that section, through fences, stopping at the next same-level heading",
       %{user: u, vault: v} do
    assert {:ok, text, %{"notes" => [n]}} = get(u, v, %{"paths" => ["P.md"], "section" => "Todo"})
    assert n["found"] == true
    assert n["content"] =~ ~r/\A## Todo\n/
    assert n["content"] =~ "## fake"
    assert n["content"] =~ "### Sub\n\ns"
    refute n["content"] =~ "## Done"
    refute n["content"] =~ "tags:"
    assert text =~ "## Todo"
  end

  test "a missing section is a fixable error that lists the headings", %{user: u, vault: v} do
    assert {:error, msg} = get(u, v, %{"paths" => ["P.md"], "section" => "Nope"})
    assert msg == "Heading not found in P.md: Nope. Headings: T, Todo, Sub, Done"

    assert {:error, "Heading not found in Q.md: Nope. This note has no headings."} =
             get(u, v, %{"paths" => ["Q.md"], "section" => "Nope"})
  end

  test "section on a missing note keeps found:false", %{user: u, vault: v} do
    assert {:ok, _, %{"notes" => [%{"path" => "Gone.md", "found" => false}]}} =
             get(u, v, %{"paths" => ["Gone.md"], "section" => "Todo"})
  end

  test "section takes one path, must be non-blank, and excludes outline", %{user: u, vault: v} do
    assert {:error, "section reads one note at a time; pass a single path"} =
             get(u, v, %{"paths" => ["P.md", "Q.md"], "section" => "Todo"})

    assert {:error, "section must name a heading, e.g. \"Todo\""} =
             get(u, v, %{"paths" => ["P.md"], "section" => " "})

    assert {:error, "Pass section or outline, not both"} =
             get(u, v, %{"paths" => ["P.md"], "section" => "Todo", "outline" => true})
  end

  # Review Focus 5
  test "outline lists real headings only, drops content, and works on many paths", %{
    user: u,
    vault: v
  } do
    assert {:ok, text, %{"notes" => [p, q, missing]}} =
             get(u, v, %{"paths" => ["P.md", "Q.md", "Gone.md"], "outline" => true})

    assert p["outline"] == [
             %{"level" => 1, "heading" => "T"},
             %{"level" => 2, "heading" => "Todo"},
             %{"level" => 3, "heading" => "Sub"},
             %{"level" => 2, "heading" => "Done"}
           ]

    refute Map.has_key?(p, "content")
    assert q["outline"] == []
    assert missing == %{"path" => "Gone.md", "found" => false}
    assert text =~ "- T\n  - Todo\n    - Sub\n  - Done"
    assert text =~ "(no headings)"
  end

  test "explicit nulls behave as absent", %{user: u, vault: v} do
    assert {:ok, _, %{"notes" => [n]}} =
             get(u, v, %{"paths" => ["P.md"], "section" => nil, "outline" => nil})

    assert n["content"] =~ "## Done"
  end
end
