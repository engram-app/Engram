defmodule Engram.Abuse.OriginClassifierTest do
  use ExUnit.Case, async: true

  alias Engram.Abuse.OriginClassifier

  describe "classify/1" do
    test "Obsidian plugin UA" do
      assert :plugin = OriginClassifier.classify("Engram-Obsidian/0.5.0 Bun/1.0")
    end

    test "CLI UA" do
      assert :cli = OriginClassifier.classify("Engram-CLI/1.2.3")
    end

    test "Web SPA UA" do
      assert :web_spa = OriginClassifier.classify("Engram-Web/0.5.155")
    end

    test "Mobile UA" do
      assert :mobile = OriginClassifier.classify("Engram-Mobile/1.0 iOS/17")
    end

    test "Claude Desktop MCP connector" do
      assert :mcp_claude_desktop = OriginClassifier.classify("Claude/0.7.5 (MCP-connector)")
    end

    test "generic MCP client" do
      assert :mcp_other = OriginClassifier.classify("modelcontextprotocol-client/0.2.1")
    end

    test "generic browser" do
      assert :browser =
               OriginClassifier.classify("Mozilla/5.0 (X11; Linux x86_64) Chrome/126.0.0.0")
    end

    test "nil/empty/unknown all classify as :unknown" do
      assert :unknown = OriginClassifier.classify(nil)
      assert :unknown = OriginClassifier.classify("")
      assert :unknown = OriginClassifier.classify("curl/7.81")
      assert :unknown = OriginClassifier.classify("custom-bot")
    end

    test "case-insensitive matching" do
      assert :plugin = OriginClassifier.classify("ENGRAM-OBSIDIAN/0.5.0")
      assert :mcp_claude_desktop = OriginClassifier.classify("ANTHROPIC-MCP/1.0")
    end
  end
end
