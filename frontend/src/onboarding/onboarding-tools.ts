// FTUX questionnaire tool catalog. Mirrors the backend `@valid_tools` list
// in lib/engram/onboarding.ex, rename a slug here and the backend will
// 422 on submit. The split between catalogs is UI-only; the wire shape is
// a flat `tools: string[]`.

export interface ToolOption {
	slug: string;
	label: string;
	hint?: string;
	/**
	 * Set when the tool cannot connect to Engram for a reason outside our
	 * control. Renders the row greyed and unselectable with this string as the
	 * explanation. Such a slug is deliberately absent from the backend
	 * `@valid_tools`, so it can never reach a profile even if the UI is bypassed.
	 */
	unavailable?: string;
}

export const TOOL_ASSISTANTS: ToolOption[] = [
	{ slug: "claude", label: "Claude" },
	{ slug: "chatgpt", label: "ChatGPT" },
	{ slug: "grok", label: "Grok" },
	{ slug: "mistral", label: "Mistral" },
	{ slug: "open_webui", label: "Open WebUI" },
	{ slug: "lobechat", label: "LobeChat" },
	// Listed-but-disabled on purpose: people look for Gemini, and a silent
	// absence reads as an Engram gap. The Gemini app has no custom-MCP-connector
	// UI (that is Gemini Enterprise / Antigravity), so we say so and point at the
	// path that works.
	{
		slug: "gemini",
		label: "Gemini",
		unavailable:
			"The Gemini app can't add custom MCP connectors. Antigravity, Google's Gemini-powered coding tool, can. Pick it under Coding tools.",
	},
];

export const TOOL_CODING: ToolOption[] = [
	{ slug: "claude_code", label: "Claude Code" },
	{ slug: "cursor", label: "Cursor" },
	{ slug: "devin", label: "Devin" },
	// Cognition acquired Windsurf in 2025 and renamed this IDE "Devin Desktop"
	// on 2026-06-02. The slug stays `windsurf` because profiles, the doc URL and
	// the brand mark all key on it; only the label reflects the current name.
	{ slug: "windsurf", label: "Devin Desktop (Windsurf)" },
	{ slug: "cline", label: "Cline" },
	{ slug: "continue", label: "Continue" },
	{ slug: "opencode", label: "OpenCode" },
	{ slug: "github_copilot", label: "GitHub Copilot" },
	// Google's supported MCP path. Deliberately no consumer "Gemini" entry, the
	// Gemini app can't add a custom remote MCP server, so that row could never
	// be completed. Antigravity replaced Gemini CLI for Pro/Ultra/free tiers on
	// 2026-06-18.
	{ slug: "antigravity", label: "Antigravity" },
	// Lives with the named clients rather than in a group of its own: it answers
	// the same question they do ("which client?"), just without naming one.
	{ slug: "other_mcp", label: "Another MCP client" },
];

/**
 * Canonical product name per slug, for surfaces that resolved a slug but only
 * have the client's self-reported name to show.
 *
 * Clients register under whatever string they like: Claude Code sends
 * `Claude Code (<mcp-server-name>)` with a user-chosen suffix, so the raw name
 * reads as "Claude Code (engram)" in the connections list. Once the slug is
 * resolved we already know the product, so prefer the catalog's spelling.
 */
export const TOOL_LABELS: Record<string, string> = Object.fromEntries(
	[...TOOL_ASSISTANTS, ...TOOL_CODING].map(({ slug, label }) => [slug, label]),
);

/**
 * The opt-out. NOT a member of the lists above, because it does not answer
 * "which client will you connect?" the way every other option does. It answers
 * "none", which makes it mutually exclusive with all of them, and a peer
 * checkbox cannot express that. The page renders it as its own control below
 * the grid and enforces the exclusivity.
 *
 * Slug stays `web_only` for wire compatibility: it is already in the backend
 * `@valid_tools` and in saved profiles. Only the presentation changed.
 */
export const NO_AI_TOOL: ToolOption = {
	slug: "web_only",
	label: "I'm not connecting an AI tool yet",
	hint: "Use Engram in the web app. You can connect a tool later from Settings.",
};
