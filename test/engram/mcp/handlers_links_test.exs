defmodule Engram.MCP.HandlersLinksTest do
  use Engram.DataCase, async: true

  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    %{user: user, a: insert(:vault, user: user), b: insert(:vault, user: user)}
  end

  # Upsert every note first, then extract links, so resolution does not depend
  # on creation order or on the async indexing job.
  defp seed(user, vault, notes) do
    saved =
      for {path, content} <- notes do
        {:ok, note} =
          Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0})

        {note, content}
      end

    for {note, content} <- saved,
        do: :ok = Links.replace_links(user, vault, note.id, Parser.extract(content))

    :ok
  end

  defp get(u, v, args),
    do: Handlers.handle("get_notes", u, v, Map.put(args, "include_links", true))

  test "found notes carry backlinks, outgoing and unresolved; a miss carries none", %{
    user: u,
    a: a
  } do
    seed(u, a, [
      {"Target.md", "# T\n\nsee [[Source]] and [[Ghost]] and [[Ghost]]"},
      {"Source.md", "see [[Target]] twice [[Target]]"}
    ])

    assert {:ok, text, %{"notes" => [t, missing]}} =
             get(u, a, %{"paths" => ["Target.md", "Nope.md"]})

    assert t["backlinks"] == ["Source.md"]
    assert t["outgoing"] == ["Source.md"]
    assert t["unresolved"] == ["Ghost"]
    assert missing == %{"path" => "Nope.md", "found" => false}
    assert text =~ "Backlinks: Source.md"
    assert text =~ "Unresolved: Ghost"
  end

  # Review Focus 4
  test "links never cross vaults", %{user: u, a: a, b: b} do
    seed(u, a, [{"Target.md", "# T"}])
    seed(u, b, [{"Source.md", "see [[Target]]"}])

    assert {:ok, _, %{"notes" => [t]}} = get(u, a, %{"paths" => ["Target.md"]})
    assert t["backlinks"] == []

    assert {:ok, _, %{"notes" => [s]}} = get(u, b, %{"paths" => ["Source.md"]})
    assert s["outgoing"] == []
    assert s["unresolved"] == ["Target"]
  end

  test "composes with outline and section", %{user: u, a: a} do
    seed(u, a, [{"Target.md", "# T\n\n## Part\n\nx"}, {"Source.md", "[[Target]]"}])

    assert {:ok, _, %{"notes" => [o]}} = get(u, a, %{"paths" => ["Target.md"], "outline" => true})
    assert o["backlinks"] == ["Source.md"]
    refute Map.has_key?(o, "content")

    assert {:ok, _, %{"notes" => [s]}} =
             get(u, a, %{"paths" => ["Target.md"], "section" => "Part"})

    assert s["backlinks"] == ["Source.md"]
    assert s["content"] =~ "## Part"
  end

  test "without the flag, or with null, the payload has no link keys", %{user: u, a: a} do
    seed(u, a, [{"A.md", "a"}])

    for args <- [%{"paths" => ["A.md"]}, %{"paths" => ["A.md"], "include_links" => nil}] do
      {:ok, _, %{"notes" => [n]}} = Handlers.handle("get_notes", u, a, args)
      refute Map.has_key?(n, "backlinks")
      refute Map.has_key?(n, "outgoing")
    end
  end
end
