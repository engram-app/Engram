defmodule EngramWeb.McpListingsStructuredOutputTest do
  @moduledoc """
  Slice 2 of #1660: the read-only listing tools. These are the ones a client
  currently has to re-parse a markdown table out of.

  Each test asserts BOTH branches (populated and empty). The `list_vaults`
  conversion taught that a single sweep call only ever exercises the branch it
  lands in, so a handler can advertise an `outputSchema` and still return a
  bare 2-tuple on the branch nothing calls.
  """
  use EngramWeb.ConnCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.MCP.Tools

  @converted ~w(search_notes list_folders list_folder list_tags)

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    grant_api_write!(user)
    %{user: user, vault: vault}
  end

  describe "outputSchema declared" do
    test "each listing tool declares one" do
      for name <- @converted do
        {:ok, tool} = Tools.get(name)
        assert is_map(tool[:outputSchema]), "#{name} has no outputSchema"
        assert tool.outputSchema["type"] == "object"
        assert is_map(tool.outputSchema["properties"]), "#{name} outputSchema needs properties"
      end
    end
  end

  describe "list_tags" do
    test "empty branch still carries the key", %{user: user, vault: vault} do
      assert {:ok, text, %{"tags" => []}} = Handlers.handle("list_tags", user, vault, %{})
      assert text =~ "No tags"
    end

    test "populated branch", %{user: user, vault: vault} do
      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "a.md",
          "content" => "---\ntags: [alpha]\n---\n\nbody"
        })

      assert {:ok, _text, %{"tags" => tags}} = Handlers.handle("list_tags", user, vault, %{})
      assert is_list(tags)
      for t <- tags, do: assert(is_binary(t["name"]) and is_integer(t["count"]))
    end
  end

  describe "list_folders" do
    test "empty branch still carries the key", %{user: user, vault: vault} do
      assert {:ok, text, %{"folders" => []}} = Handlers.handle("list_folders", user, vault, %{})
      assert text =~ "No folders"
    end

    test "populated branch", %{user: user, vault: vault} do
      {:ok, _} = Engram.Notes.upsert_note(user, vault, %{"path" => "Deep/a.md", "content" => "x"})

      assert {:ok, _text, %{"folders" => folders}} =
               Handlers.handle("list_folders", user, vault, %{})

      assert Enum.any?(folders, &(&1["folder"] == "Deep"))
      for f <- folders, do: assert(is_integer(f["count"]))
    end
  end

  describe "list_folder" do
    test "empty branch still carries both keys", %{user: user, vault: vault} do
      assert {:ok, text, structured} = Handlers.handle("list_folder", user, vault, %{})
      assert structured["notes"] == []
      assert structured["attachments"] == []
      assert text =~ "No notes"
    end

    test "populated branch", %{user: user, vault: vault} do
      {:ok, _} = Engram.Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "hi"})

      assert {:ok, _text, structured} = Handlers.handle("list_folder", user, vault, %{})
      assert [%{"path" => "a.md"} | _] = structured["notes"]
      assert structured["folder"] == ""
    end

    test "a listing failure is an error, not an ok carrying an excuse" do
      # Was `{:ok, "Could not list folder ..."}` — a client saw success, and
      # the reason was `inspect/1`ed into the body.
      assert {:error, msg} = Handlers.render_folder({:error, :boom}, "Notes")
      refute msg =~ "boom"
    end
  end

  describe "search_notes" do
    test "empty branch still carries the key" do
      assert {:ok, text, %{"results" => []}} = Handlers.render_search({:ok, []}, %{})
      assert text =~ "No results"
    end

    test "populated branch carries each hit as data" do
      hit = %{score: 0.5, title: "T", source_path: "a.md", text: "body", tags: ["x"]}

      assert {:ok, _text, %{"results" => [r]}} = Handlers.render_search({:ok, [hit]}, %{})
      assert r["title"] == "T"
      assert r["source_path"] == "a.md"
      assert r["score"] == 0.5
    end

    test "a search outage is an error, not an ok carrying an excuse" do
      # Was `{:ok, "Search unavailable."}` — an outage reported as success, so
      # no client could distinguish it from a genuine zero-hit search.
      assert {:error, _} = Handlers.render_search({:error, :qdrant_down}, %{})
    end

    test "a spent plan budget stays a distinguishable error" do
      assert {:error, msg} = Handlers.render_search({:error, :search_cap_exceeded, 50}, %{})
      assert msg =~ "ai_searches_per_day"
    end
  end
end
