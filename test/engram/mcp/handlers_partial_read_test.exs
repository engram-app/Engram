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

  # --- Fix round (adversarial): large notes and ambiguous headings ---

  defp big_note(heading, bytes) do
    body = "## #{heading}\n" <> String.duplicate("word ", div(bytes, 5)) <> "\n"
    binary_part(body, 0, bytes)
  end

  # No size cap and no per-call budget: concurrency is bounded instead.
  test "section and outline work on notes over 1 MB", %{user: u, vault: v} do
    for path <- ["O1.md", "O2.md", "O3.md"] do
      {:ok, _} =
        Notes.upsert_note(u, v, %{
          "path" => path,
          "content" => big_note("H", 1_100_000),
          "mtime" => 1.0
        })
    end

    assert {:ok, _, %{"notes" => [%{"content" => "## H\nword" <> _}]}} =
             get(u, v, %{"paths" => ["O1.md"], "section" => "H"})

    assert {:ok, _, %{"notes" => notes}} =
             get(u, v, %{"paths" => ["O1.md", "O2.md", "O3.md"], "outline" => true})

    assert Enum.all?(notes, &match?(%{"outline" => [%{"heading" => "H"}]}, &1))
    refute Enum.any?(notes, &Map.has_key?(&1, "error"))
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

  # --- Round: one deadline per call ---

  # Holds the only slot of a per-test gate and points this test process's
  # handler calls at it (process-local seam, no global env).
  defp held_gate(deadline_ms) do
    g = start_supervised!({Engram.MCP.ParseGate, name: nil, limit: 1, max_waiting: 4})
    test = self()

    Task.start(fn ->
      Engram.MCP.ParseGate.run(
        fn ->
          send(test, {:holding, self()})
          receive do: (:go -> :ok)
        end,
        gate: g,
        parse_timeout: :infinity
      )
    end)

    assert_receive {:holding, w}, 5_000
    Process.put(:engram_parse_gate_opts, gate: g, deadline_ms: deadline_ms)
    on_exit(fn -> send(w, :go) end)
    w
  end

  test "outline over several paths stops at the call's deadline with per-note errors",
       %{user: u, vault: v} do
    held_gate(100)
    paths = for i <- 1..4, do: "D#{i}.md"

    for p <- paths do
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => p, "content" => "## H\n", "mtime" => 1.0})
    end

    assert {:ok, text, %{"notes" => notes}} = get(u, v, %{"paths" => paths, "outline" => true})
    assert length(notes) == 4

    for n <- notes do
      assert n["found"] == true and not Map.has_key?(n, "outline")
      assert n["error"] =~ "ran out of time"
    end

    assert text =~ "ran out of time"
  end

  test "a section read past the deadline is a fixable error", %{user: u, vault: v} do
    held_gate(50)
    assert {:error, msg} = get(u, v, %{"paths" => ["P.md"], "section" => "Todo"})
    assert msg =~ "ran out of time"
  end
end
