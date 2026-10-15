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
end
