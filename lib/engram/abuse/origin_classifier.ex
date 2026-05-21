defmodule Engram.Abuse.OriginClassifier do
  @moduledoc """
  Pricing v2 §E — pure classifier from raw User-Agent string to a fixed
  set of origin classes. Used to spot Pro accounts where the bulk of MCP
  traffic doesn't originate from a known Engram client (plugin / web SPA /
  mobile / Claude Desktop MCP).

  Returns one of:

    - `:plugin`              — Obsidian plugin
    - `:web_spa`             — engram.page React app
    - `:mobile`              — future Engram mobile app
    - `:mcp_claude_desktop`  — Anthropic Claude Desktop's MCP connector
    - `:mcp_other`           — other MCP clients (Codex, custom, etc.)
    - `:cli`                 — Engram CLI tooling
    - `:browser`             — generic browser hitting the API directly
    - `:unknown`             — no match (high-share unknown is the §E signal)
  """

  @type class ::
          :plugin
          | :web_spa
          | :mobile
          | :mcp_claude_desktop
          | :mcp_other
          | :cli
          | :browser
          | :unknown

  @spec classify(String.t() | nil) :: class()
  def classify(nil), do: :unknown
  def classify(""), do: :unknown

  def classify(ua) when is_binary(ua) do
    ua_down = String.downcase(ua)

    cond do
      String.contains?(ua_down, "engram-obsidian") -> :plugin
      String.contains?(ua_down, "engram-mobile") -> :mobile
      String.contains?(ua_down, "engram-cli") -> :cli
      String.contains?(ua_down, "engram-web") -> :web_spa
      claude_desktop?(ua_down) -> :mcp_claude_desktop
      mcp_other?(ua_down) -> :mcp_other
      browser?(ua_down) -> :browser
      true -> :unknown
    end
  end

  # Claude Desktop's MCP connector self-identifies; substring is stable.
  defp claude_desktop?(ua),
    do: String.contains?(ua, "claude") or String.contains?(ua, "anthropic")

  defp mcp_other?(ua), do: String.contains?(ua, "mcp/") or String.contains?(ua, "modelcontext")

  # Generic browser markers — Mozilla token is universal in browser UAs but
  # absent from purpose-built clients.
  defp browser?(ua) do
    String.contains?(ua, "mozilla") or String.contains?(ua, "chrome") or
      String.contains?(ua, "safari") or String.contains?(ua, "firefox")
  end
end
