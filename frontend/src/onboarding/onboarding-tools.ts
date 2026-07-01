// FTUX questionnaire tool catalog. Mirrors the backend `@valid_tools` list
// in lib/engram/onboarding.ex — rename a slug here and the backend will
// 422 on submit. The split between catalogs is UI-only; the wire shape is
// a flat `tools: string[]`.

export interface ToolOption {
	slug: string;
	label: string;
	hint?: string;
}

export const TOOL_ASSISTANTS: ToolOption[] = [
	{ slug: "claude", label: "Claude" },
	{ slug: "chatgpt", label: "ChatGPT" },
	{ slug: "grok", label: "Grok" },
	{ slug: "mistral", label: "Mistral" },
	{ slug: "open_webui", label: "Open WebUI" },
	{ slug: "lobechat", label: "LobeChat" },
];

export const TOOL_CODING: ToolOption[] = [
	{ slug: "claude_code", label: "Claude Code" },
	{ slug: "cursor", label: "Cursor" },
	{ slug: "windsurf", label: "Windsurf" },
	{ slug: "cline", label: "Cline" },
	{ slug: "continue", label: "Continue" },
	{ slug: "opencode", label: "OpenCode" },
	{ slug: "github_copilot", label: "GitHub Copilot" },
];

export const TOOL_OTHER: ToolOption[] = [
	{ slug: "web_only", label: "Just the web app" },
	{ slug: "other_mcp", label: "Other connection" },
];
