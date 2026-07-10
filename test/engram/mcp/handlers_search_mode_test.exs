defmodule Engram.MCP.HandlersSearchModeTest do
  use ExUnit.Case, async: true

  alias Engram.MCP.Handlers
  alias Engram.MCP.Tools

  test "search_notes tool advertises the mode enum" do
    tool = Enum.find(Tools.list(), &(&1.name == "search_notes"))
    assert tool.inputSchema["properties"]["mode"]["enum"] == ["hybrid", "keyword", "vector"]
    assert tool.inputSchema["properties"]["mode"]["default"] == "hybrid"
  end

  test "search_notes vault_id is an OPTIONAL narrower (searches all vaults by default)" do
    tool = Enum.find(Tools.list(), &(&1.name == "search_notes"))
    vault_id = tool.inputSchema["properties"]["vault_id"]

    assert vault_id["type"] == "string"
    # Not required (unlike navigation/write tools, which need it when multi-vault).
    refute "vault_id" in (tool.inputSchema["required"] || [])
    assert vault_id["description"] =~ "ALL your vaults"
  end

  test "mode arg maps to the Search opt (unknown falls back to hybrid)" do
    assert Handlers.search_mode(%{"mode" => "keyword"}) == :keyword
    assert Handlers.search_mode(%{"mode" => "vector"}) == :vector
    assert Handlers.search_mode(%{"mode" => "nonsense"}) == :hybrid
    assert Handlers.search_mode(%{}) == :hybrid
  end

  describe "build_search_opts/1" do
    test "threads diversity into opts when given a float" do
      opts = Handlers.build_search_opts(%{"diversity" => 0.7})
      assert Keyword.get(opts, :diversity) == 0.7
    end

    test "threads diversity into opts when given 0.0 (boundary)" do
      opts = Handlers.build_search_opts(%{"diversity" => 0.0})
      assert Keyword.get(opts, :diversity) == 0.0
    end

    test "threads diversity into opts when given 1.0 (boundary)" do
      opts = Handlers.build_search_opts(%{"diversity" => 1.0})
      assert Keyword.get(opts, :diversity) == 1.0
    end

    test "omits diversity key when absent" do
      opts = Handlers.build_search_opts(%{})
      refute Keyword.has_key?(opts, :diversity)
    end

    test "omits diversity key when value is a string (non-number)" do
      opts = Handlers.build_search_opts(%{"diversity" => "high"})
      refute Keyword.has_key?(opts, :diversity)
    end

    test "includes default limit and mode" do
      opts = Handlers.build_search_opts(%{})
      assert Keyword.get(opts, :limit) == 5
      assert Keyword.get(opts, :mode) == :hybrid
    end

    test "threads tags into opts when provided" do
      opts = Handlers.build_search_opts(%{"tags" => ["elixir", "phoenix"]})
      assert Keyword.get(opts, :tags) == ["elixir", "phoenix"]
    end

    test "search_notes tool advertises diversity property" do
      tool = Enum.find(Tools.list(), &(&1.name == "search_notes"))
      diversity = tool.inputSchema["properties"]["diversity"]
      assert diversity["type"] == "number"
      assert diversity["minimum"] == 0
      assert diversity["maximum"] == 1
      refute "diversity" in (tool.inputSchema["required"] || [])
    end

    test "build_search_opts plumbs folder, type and date bounds" do
      opts =
        Handlers.build_search_opts(%{
          "query" => "x",
          "folder" => "projects",
          "type" => "Playbook",
          "updated_after" => "2026-01-01T00:00:00Z",
          "created_before" => "bogus"
        })

      assert opts[:folder] == "projects"
      assert opts[:type] == "Playbook"
      assert opts[:updated_after] == ~U[2026-01-01 00:00:00Z]
      refute Keyword.has_key?(opts, :created_before)
    end

    test "search_notes tool advertises folder, type and date-range properties" do
      tool = Enum.find(Tools.list(), &(&1.name == "search_notes"))
      props = tool.inputSchema["properties"]

      assert props["folder"]["type"] == "string"
      assert props["type"]["type"] == "string"

      for key <- ~w(created_after created_before updated_after updated_before) do
        assert props[key]["type"] == "string"
      end
    end
  end
end
