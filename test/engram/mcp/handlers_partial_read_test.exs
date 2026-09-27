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

  test "the missing-section heading list is capped at 50 and each heading truncated to 100 chars",
       %{user: u, vault: v} do
    headings = Enum.map(1..60, &"H#{&1}")
    content = Enum.map_join(headings, "\n\n", &"## #{&1}") <> "\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Many.md", "content" => content, "mtime" => 1.0})

    assert {:error, msg} = get(u, v, %{"paths" => ["Many.md"], "section" => "Nope"})
    assert msg =~ "and 10 more"
    assert Enum.all?(Enum.take(headings, 50), &(msg =~ &1))
    refute msg =~ "H51"

    long = String.duplicate("x", 150)
    content2 = "## #{long}\n\nbody\n"

    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "Long.md", "content" => content2, "mtime" => 1.0})

    assert {:error, msg2} = get(u, v, %{"paths" => ["Long.md"], "section" => "Nope"})
    assert msg2 =~ "#{String.duplicate("x", 100)}..."
    refute msg2 =~ String.duplicate("x", 101)
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

  # Regression: neither section nor outline present must keep the pre-Task-3
  # get_notes shape (full content, no outline key).
  test "plain get_notes without section or outline keeps the original content shape",
       %{user: u, vault: v} do
    assert {:ok, text, %{"notes" => [n]}} = get(u, v, %{"paths" => ["P.md"]})

    assert n["found"] == true
    assert n["content"] =~ "## Done"
    refute Map.has_key?(n, "outline")
    assert text =~ "**Path:** P.md"
  end

  # --- Fix round (adversarial): size caps and ambiguous headings ---

  defp big_note(heading, bytes) do
    body = "## #{heading}\n" <> String.duplicate("word ", div(bytes, 5)) <> "\n"
    binary_part(body, 0, bytes)
  end

  test "section on a note over 1 MB is a fixable too-large error", %{user: u, vault: v} do
    {:ok, _} =
      Notes.upsert_note(u, v, %{
        "path" => "Huge.md",
        "content" => big_note("A", 1_100_000),
        "mtime" => 1.0
      })

    assert {:error, msg} = get(u, v, %{"paths" => ["Huge.md"], "section" => "A"})

    assert msg ==
             "This note is too large for section edits or outline (1.1 MB, limit 1 MB); " <>
               "use edit_note replace_text or read the note with get_notes"
  end

  test "outline gives a per-note error past 1 MB or the 2 MB call budget, not a failed call",
       %{user: u, vault: v} do
    for {path, bytes} <- [{"O1.md", 900_000}, {"O2.md", 900_000}, {"O3.md", 900_000}] do
      {:ok, _} =
        Notes.upsert_note(u, v, %{
          "path" => path,
          "content" => big_note("H", bytes),
          "mtime" => 1.0
        })
    end

    {:ok, _} =
      Notes.upsert_note(u, v, %{
        "path" => "O4.md",
        "content" => big_note("H", 1_100_000),
        "mtime" => 1.0
      })

    assert {:ok, text, %{"notes" => [n4, n1, n2, n3, p]}} =
             get(u, v, %{
               "paths" => ["O4.md", "O1.md", "O2.md", "O3.md", "P.md"],
               "outline" => true
             })

    assert n4["found"] == true and n4["error"] =~ "too large" and not Map.has_key?(n4, "outline")
    assert [%{"heading" => "H"}] = n1["outline"]
    assert [%{"heading" => "H"}] = n2["outline"]
    assert n3["found"] == true and n3["error"] =~ "2 MB outline budget"
    refute Map.has_key?(n3, "outline")
    # A small note after the budget is spent still fits.
    assert [_ | _] = p["outline"]
    assert text =~ "Outline skipped"
  end

  test "a section name that only renders like several headings is a fixable error",
       %{user: u, vault: v} do
    {:ok, _} =
      Notes.upsert_note(u, v, %{
        "path" => "Amb.md",
        "content" => "## **A**\nx\n## *A*\ny\n",
        "mtime" => 1.0
      })

    assert {:error, "Heading 'A' matches several headings; pass the exact heading text"} =
             get(u, v, %{"paths" => ["Amb.md"], "section" => "A"})

    assert {:ok, _, %{"notes" => [%{"content" => "## *A*\ny"}]}} =
             get(u, v, %{"paths" => ["Amb.md"], "section" => "*A*"})
  end
end
