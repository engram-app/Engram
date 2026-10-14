import { msg } from "@/i18n/msg";
import { type MsgKey, type UIText, untranslated } from "@/i18n/ui-text";

// FTUX questionnaire tool catalog. Mirrors the backend `@valid_tools` list
// in lib/engram/onboarding.ex, rename a slug here and the backend will
// 422 on submit. The split between catalogs is UI-only; the wire shape is
// a flat `tools: string[]`.

export type ToolOption = {
	slug: string;
	hint?: MsgKey;
	/**
	 * Set when the tool cannot connect to Engram for a reason outside our
	 * control. Renders the row greyed and unselectable with this string as the
	 * explanation. Such a slug is deliberately absent from the backend
	 * `@valid_tools`, so it can never reach a profile even if the UI is bypassed.
	 */
	unavailable?: MsgKey;
} & (
	| { label: UIText; translate?: undefined }
	/** Set on labels written with `msg()`. Brand names stay as written, even when one equals a catalog key. */
	| { label: MsgKey; translate: true }
);

export const TOOL_ASSISTANTS: ToolOption[] = [
	{ slug: "claude", label: untranslated("Claude") },
	{ slug: "chatgpt", label: untranslated("ChatGPT") },
	{ slug: "grok", label: untranslated("Grok") },
	{ slug: "mistral", label: untranslated("Mistral") },
	{ slug: "open_webui", label: untranslated("Open WebUI") },
	{ slug: "lobechat", label: untranslated("LobeChat") },
	// Listed-but-disabled on purpose: people look for Gemini, and a silent
	// absence reads as an Engram gap. The Gemini app has no custom-MCP-connector
	// UI (that is Gemini Enterprise / Antigravity), so we say so and point at the
	// path that works.
	{
		slug: "gemini",
		label: untranslated("Gemini"),
		unavailable: msg(
			"The Gemini app can't add custom MCP connectors. Antigravity, Google's Gemini-powered coding tool, can. Pick it under Coding tools.",
		),
	},
];

export const TOOL_CODING: ToolOption[] = [
	{ slug: "claude_code", label: untranslated("Claude Code") },
	{ slug: "cursor", label: untranslated("Cursor") },
	{ slug: "devin", label: untranslated("Devin") },
	// Cognition acquired Windsurf in 2025 and renamed this IDE "Devin Desktop"
	// on 2026-06-02. The slug stays `windsurf` because profiles, the doc URL and
	// the brand mark all key on it; only the label reflects the current name.
	{ slug: "windsurf", label: untranslated("Devin Desktop (Windsurf)") },
	{ slug: "cline", label: untranslated("Cline") },
	{ slug: "continue", label: untranslated("Continue") },
	{ slug: "opencode", label: untranslated("OpenCode") },
	{ slug: "github_copilot", label: untranslated("GitHub Copilot") },
	// Google's supported MCP path. Deliberately no consumer "Gemini" entry, the
	// Gemini app can't add a custom remote MCP server, so that row could never
	// be completed. Antigravity replaced Gemini CLI for Pro/Ultra/free tiers on
	// 2026-06-18.
	{ slug: "antigravity", label: untranslated("Antigravity") },
	// Lives with the named clients rather than in a group of its own: it answers
	// the same question they do ("which client?"), just without naming one.
	{ slug: "other_mcp", label: msg("Another MCP client"), translate: true },
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
// Brand names only: a msg() label ("Another MCP client") names no product, and
// it is an untranslated key, so it must not be rendered from here.
export const TOOL_LABELS: Record<string, UIText> = Object.fromEntries(
	[...TOOL_ASSISTANTS, ...TOOL_CODING].flatMap((o) => (o.translate ? [] : [[o.slug, o.label]])),
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
export const NO_AI_TOOL = {
	slug: "web_only",
	label: msg("I'm not connecting an AI tool yet"),
	translate: true,
	hint: msg("Use Engram in the web app. You can connect a tool later from Settings."),
} as const satisfies ToolOption;
