// FTUX questionnaire tool catalog. Mirrors the backend `@valid_tools` list
// in lib/engram/onboarding.ex — rename a slug here and the backend will
// 422 on submit. The split between `apps` and `dev` is UI-only; the wire
// shape is a flat `tools: string[]`.

export interface ToolOption {
  slug: string
  label: string
  hint?: string
}

export const TOOL_APPS: ToolOption[] = [
  { slug: 'claude', label: 'Claude (Desktop + mobile)' },
  { slug: 'chatgpt', label: 'ChatGPT' },
  { slug: 'web_only', label: 'Just the web app' },
]

export const TOOL_DEV: ToolOption[] = [
  { slug: 'claude_code', label: 'Claude Code' },
  { slug: 'cursor', label: 'Cursor' },
  { slug: 'continue_cline', label: 'Continue / Cline' },
  { slug: 'other_mcp', label: 'Other MCP client' },
]

export const ALL_TOOL_SLUGS: ReadonlySet<string> = new Set(
  [...TOOL_APPS, ...TOOL_DEV].map((t) => t.slug),
)
