defmodule Engram.Analytics.McpClientTest do
  # Third review of #1974: a CIMD host is attacker-chosen (anyone can publish
  # a client document at `claude.ai.evil.example`), so a vendor label from a
  # host is only given on an EXACT host match. A substring match let any
  # domain claim to be a vendor in our metrics.
  use ExUnit.Case, async: true

  alias Engram.Analytics.McpClient
  alias Engram.OAuth.Client

  test "a known vendor host maps to its family" do
    assert McpClient.host_family("chatgpt.com") == "chatgpt"
    assert McpClient.host_family("claude.ai") == "claude"
    assert McpClient.host_family("Claude.AI") == "claude"
  end

  for host <- [
        "chatgpt.com.evil.example",
        "evilclaude.ai",
        "claude.ai.attacker.dev",
        "my-zed.dev"
      ] do
    test "#{host} is other" do
      assert McpClient.host_family(unquote(host)) == "other"
    end
  end

  test "a CIMD client is labelled by its exact document host" do
    assert {"chatgpt", "cimd"} =
             McpClient.of_client(%Client{cimd_url: "https://chatgpt.com/oauth/client.json"})

    assert {"other", "cimd"} =
             McpClient.of_client(%Client{cimd_url: "https://chatgpt.com.evil.example/c.json"})
  end

  # Codex and ChatGPT share OpenAI's CIMD document, so both are "chatgpt" by
  # client. The token request's User-Agent tells them apart.
  describe "agent/2" do
    test "the Codex CLI is codex" do
      assert McpClient.agent("codex-mcp-client/0.46.0", "chatgpt") == "codex"
    end

    test "ChatGPT's connector backend is chatgpt" do
      assert McpClient.agent("openai-connectors-oauth/1.0", "chatgpt") == "chatgpt"
    end

    test "anything else is the client family" do
      assert McpClient.agent("python-httpx/0.27.0", "claude") == "claude"
      assert McpClient.agent(nil, "other") == "other"
      assert McpClient.agent("", "cursor") == "cursor"
    end

    test "a UA that only mentions codex later is not codex" do
      assert McpClient.agent("evil/1.0 codex-mcp-client/1", "other") == "other"
    end

    test "ChatGPT's MCP requests are chatgpt" do
      assert McpClient.agent("openai-mcp/1.0.0", "other") == "chatgpt"
    end
  end

  # 2026-10-24: Codex < 0.164 races refresh rotation (openai/codex#46028), so
  # we need the share of Codex on a fixed release, from a bounded value.
  describe "version/2" do
    test "reads major.minor from clientInfo.version first" do
      assert McpClient.version("0.164.0", "codex-mcp-client/0.163.0") == "0.164"
    end

    test "falls back to the User-Agent's version token" do
      assert McpClient.version(nil, "codex-mcp-client/0.163.0-alpha.11") == "0.163"
      assert McpClient.version(nil, "codex-mcp-client/0.164.0") == "0.164"
      assert McpClient.version(%{"x" => 1}, "claude-code/2.1.303 (cli)") == "2.1"
    end

    test "leading zeros are normalized" do
      assert McpClient.version("01.0164", nil) == "1.164"
    end

    test "anything else is nil, never client text" do
      assert McpClient.version(nil, nil) == nil
      assert McpClient.version("latest", "node") == nil
      assert McpClient.version("<script>1.2", "x/<b>") == nil
      assert McpClient.version("12345.1", nil) == nil
      assert McpClient.version("1.12345", nil) == nil
      assert McpClient.version(String.duplicate("9", 10_000), nil) == nil
    end
  end
end
