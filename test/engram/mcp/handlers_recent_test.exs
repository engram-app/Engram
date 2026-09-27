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
      Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "# R\n\nx", "mtime" => 1.0})

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
    {:ok, _} = Notes.upsert_note(u, other, %{"path" => "o.md", "content" => "o", "mtime" => 2.0})

    assert {:ok, _, %{"results" => [first, second]}} =
             Handlers.handle("search_notes", u, {:cross_vault, [v, other]}, %{"limit" => 5})

    assert {first["source_path"], first["vault"]} == {"o.md", "Other"}
    assert second["source_path"] == "r.md"
    assert second["vault_id"] == to_string(v.id)
  end

  test "a filter without a query is a fixable error; a null filter is not", %{user: u, vault: v} do
    assert {:error, "tags needs a query or similar_to; omit it to list recently updated notes"} =
             Handlers.handle("search_notes", u, v, %{"tags" => ["x"]})

    assert {:ok, _, _} =
             Handlers.handle("search_notes", u, v, %{
               "tags" => nil,
               "mode" => "hybrid",
               "diversity" => 0.3
             })
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
