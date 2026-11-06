defmodule Engram.MCP.HandlersRecentTest do
  use Engram.DataCase, async: true

  import Mox

  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup :verify_on_exit!

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "# R\n\nx", "mtime" => 1.0},
        actor: "api"
      )

    # Review Focus 3: the embedder must never be called on this path.
    expect(Engram.MockEmbedder, :embed_texts, 0, fn _texts, _opts -> flunk("must not embed") end)
    %{user: user, vault: vault}
  end

  for q <- [:absent, nil, "", "   "] do
    test "query #{inspect(q)} lists recent notes without searching", %{user: u, vault: v} do
      args = if unquote(q) == :absent, do: %{}, else: %{"query" => unquote(q)}

      assert {:ok, text, %{"results" => [hit]}} = Handlers.handle("search_notes", u, v, args)
      assert hit["source_path"] == "r.md"
      assert hit["score"] == 0
      refute Map.has_key?(hit, "vault")
      assert text =~ "Recently updated"
    end
  end

  # Review Focus 3: no budget spend. Cap 0 refuses every Search.search/4 call
  # (control), and the recent listing still answers.
  test "a zero search budget does not block the listing", %{user: u, vault: v} do
    insert(:user_limit_override, user: u, key: "ai_searches_per_day", value: %{"v" => 0})
    assert {:error, :search_cap_exceeded, 0} = Engram.Search.search(u, v, "anything")

    assert {:ok, _, %{"results" => [_]}} =
             Handlers.handle("search_notes", u, v, %{"query" => " "})
  end

  test "cross-vault listing merges newest first and labels vaults", %{user: u, vault: v} do
    other = insert(:vault, user: u, name: "Other")
    Process.sleep(2)

    {:ok, _} =
      Notes.upsert_note(u, other, %{"path" => "o.md", "content" => "o", "mtime" => 2.0},
        actor: "api"
      )

    assert {:ok, _, %{"results" => [first, second]}} =
             Handlers.handle("search_notes", u, {:cross_vault, [v, other]}, %{"limit" => 5})

    assert {first["source_path"], first["vault"]} == {"o.md", "Other"}
    assert second["source_path"] == "r.md"
    assert second["vault_id"] == to_string(v.id)
  end

  # #2083: filters with no query are answered in Postgres (no embed, no budget).
  test "a filter without a query lists the matching notes; a null filter is no filter",
       %{user: u, vault: v} do
    # Tag filters read note_attrs, which the index pass writes.
    Engram.FieldCatalogHelpers.write_indexed!(u, v, "t.md", "---\ntags: [x]\n---\nt")

    assert {:ok, text, %{"results" => [hit]}} =
             Handlers.handle("search_notes", u, v, %{"tags" => ["x"]})

    assert hit["source_path"] == "t.md"
    assert text =~ "Recently updated"

    assert {:ok, "No notes match these filters.", %{"results" => []}} =
             Handlers.handle("search_notes", u, v, %{"tags" => ["nope"]})

    assert {:ok, _, %{"results" => [_]}} =
             Handlers.handle("search_notes", u, {:cross_vault, [v]}, %{"tags" => ["x"]})

    assert {:error, msg} =
             Handlers.handle("search_notes", u, v, %{
               "fields" => [%{"key" => "nope", "value" => 1}]
             })

    assert msg =~ "nope"

    assert {:ok, _, _} =
             Handlers.handle("search_notes", u, v, %{
               "tags" => nil,
               "mode" => "hybrid",
               "diversity" => 0.3
             })
  end

  # Dropping the only filter would list every recent note as if filtered.
  test "a filter-only call with a param that does not parse is an error", %{user: u, vault: v} do
    assert {:error, msg} =
             Handlers.handle("search_notes", u, v, %{"updated_after" => "last tuesday"})

    assert msg =~ "updated_after"

    assert {:error, msg} = Handlers.handle("search_notes", u, v, %{"folder" => 5})
    assert msg =~ "folder"
  end

  test "limit 0 or negative floors to 1 instead of crashing", %{user: u, vault: v} do
    assert {:ok, _, %{"results" => [_]}} = Handlers.handle("search_notes", u, v, %{"limit" => 0})
    assert {:ok, _, %{"results" => [_]}} = Handlers.handle("search_notes", u, v, %{"limit" => -3})
  end

  test "cross-vault: limit 0 or negative floors to 1 instead of crashing", %{user: u, vault: v} do
    other = insert(:vault, user: u)

    {:ok, _} =
      Notes.upsert_note(u, other, %{"path" => "o.md", "content" => "o", "mtime" => 2.0},
        actor: "api"
      )

    assert {:ok, _, %{"results" => [_]}} =
             Handlers.handle("search_notes", u, {:cross_vault, [v, other]}, %{"limit" => 0})

    assert {:ok, _, %{"results" => [_]}} =
             Handlers.handle("search_notes", u, {:cross_vault, [v, other]}, %{"limit" => -3})
  end

  test "an empty vault answers 'No notes yet.'", %{user: u} do
    empty = insert(:vault, user: u)

    assert {:ok, "No notes yet.", %{"results" => []}} =
             Handlers.handle("search_notes", u, empty, %{})
  end

  test "query is no longer required in the schema" do
    {:ok, tool} = Engram.MCP.Tools.get("search_notes")
    refute "query" in (tool.inputSchema["required"] || [])
  end
end
