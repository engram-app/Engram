import { useEffect, useState, type ReactNode } from 'react'
import type { OnboardingProfile } from '../api/queries'

// Stable LS key per slug. Cards are device-local; cross-device dismiss
// can come later if users complain (it would need a new actions table).
const LS_KEY = 'engram:setup-cards-dismissed:v1'

interface CardDef {
  key: string
  title: string
  body: ReactNode
  // True when the card has real, copy-pasteable setup content. The rest
  // are stub placeholders so a user with that tool still sees the slot,
  // and we can fill in the snippet later without changing the trigger.
  ready: boolean
}

function mcpUrl(): string {
  if (typeof window === 'undefined') return '/api/mcp'
  return `${window.location.origin}/api/mcp`
}

function ObsidianCardBody() {
  return (
    <p>
      Open Obsidian → <kbd className="kbd-inline">Settings → Community
      plugins → Browse</kbd>, search for <em>Engram</em>, install + enable.
      Your first sync creates the vault here automatically — no empty
      placeholder.
    </p>
  )
}

function ClaudeDesktopCardBody() {
  return (
    <>
      <p>
        Open Claude Desktop → <kbd className="kbd-inline">Settings →
        Connectors → Add custom connector</kbd>. Paste this URL:
      </p>
      <CodeBlock>{mcpUrl()}</CodeBlock>
      <p className="text-xs text-muted-foreground">
        Sign in with your Engram account when prompted. Mobile Claude uses
        the same connector — it syncs automatically once Desktop is wired.
      </p>
    </>
  )
}

function CursorCardBody() {
  return (
    <>
      <p>
        Add Engram to <code className="code-inline">~/.cursor/mcp.json</code>
        (or <code className="code-inline">.cursor/mcp.json</code> in the
        workspace):
      </p>
      <CodeBlock>
        {`{
  "mcpServers": {
    "engram": {
      "url": "${mcpUrl()}"
    }
  }
}`}
      </CodeBlock>
      <p className="text-xs text-muted-foreground">
        Cursor will prompt you to sign in on first tool call.
      </p>
    </>
  )
}

function ComingSoon({ name }: { name: string }) {
  return (
    <p className="text-sm text-muted-foreground">
      {name} setup instructions are landing soon. In the meantime you can
      point any MCP client at <code className="code-inline">{mcpUrl()}</code>.
    </p>
  )
}

function WebOnlyCardBody() {
  return (
    <p>
      You picked the web app — you're already in it. Create your first note
      from the sidebar to get started. We'll surface power tools (search,
      AI summaries) as your vault fills up.
    </p>
  )
}

function CodeBlock({ children }: { children: ReactNode }) {
  return (
    <pre className="my-2 overflow-x-auto rounded-md bg-muted px-3 py-2 text-xs text-foreground">
      <code>{children}</code>
    </pre>
  )
}

// Cards keyed by the trigger that surfaces them. Order here = render order.
const CARDS = {
  install_obsidian_plugin: {
    key: 'install_obsidian_plugin',
    title: 'Install the Engram Obsidian plugin',
    body: <ObsidianCardBody />,
    ready: true,
  },
  claude: {
    key: 'claude',
    title: 'Connect Claude Desktop',
    body: <ClaudeDesktopCardBody />,
    ready: true,
  },
  cursor: {
    key: 'cursor',
    title: 'Configure Cursor MCP',
    body: <CursorCardBody />,
    ready: true,
  },
  claude_code: {
    key: 'claude_code',
    title: 'Add Engram to Claude Code',
    body: <ComingSoon name="Claude Code" />,
    ready: false,
  },
  chatgpt: {
    key: 'chatgpt',
    title: 'Connect ChatGPT',
    body: <ComingSoon name="ChatGPT" />,
    ready: false,
  },
  continue_cline: {
    key: 'continue_cline',
    title: 'Configure Continue / Cline',
    body: <ComingSoon name="Continue / Cline" />,
    ready: false,
  },
  other_mcp: {
    key: 'other_mcp',
    title: 'Generic MCP endpoint',
    body: <ComingSoon name="Your MCP client" />,
    ready: false,
  },
  web_only: {
    key: 'web_only',
    title: 'Start writing in the web app',
    body: <WebOnlyCardBody />,
    ready: true,
  },
} as const satisfies Record<string, CardDef>

// Render the obsidian card first when the user opted in, then the picked
// tools in the order they appear in `profile.tools`. Stub cards still
// surface so users see *something* against every selected tool.
function cardsFor(profile: OnboardingProfile): CardDef[] {
  const ordered: CardDef[] = []
  if (profile.uses_obsidian) ordered.push(CARDS.install_obsidian_plugin)
  for (const slug of profile.tools) {
    const card = (CARDS as Record<string, CardDef | undefined>)[slug]
    if (card) ordered.push(card)
  }
  return ordered
}

function loadDismissed(): Set<string> {
  if (typeof window === 'undefined') return new Set()
  try {
    const raw = window.localStorage.getItem(LS_KEY)
    if (!raw) return new Set()
    const arr = JSON.parse(raw)
    return new Set(Array.isArray(arr) ? arr : [])
  } catch {
    return new Set()
  }
}

function persistDismissed(set: Set<string>) {
  if (typeof window === 'undefined') return
  window.localStorage.setItem(LS_KEY, JSON.stringify([...set]))
}

interface Props {
  profile: OnboardingProfile
}

export function SetupCards({ profile }: Props) {
  const [dismissed, setDismissed] = useState<Set<string>>(() => loadDismissed())
  const [collapsed, setCollapsed] = useState(false)

  useEffect(() => {
    persistDismissed(dismissed)
  }, [dismissed])

  function dismiss(key: string) {
    setDismissed((prev) => {
      const next = new Set(prev)
      next.add(key)
      return next
    })
  }

  const visible = cardsFor(profile).filter((c) => !dismissed.has(c.key))

  if (visible.length === 0) return null

  return (
    <section
      aria-label="Setup checklist"
      className="mb-4 rounded-xl border border-border bg-card p-4 shadow-sm"
    >
      <header className="mb-3 flex items-center justify-between">
        <div>
          <h2 className="text-base font-semibold text-foreground">
            Finish setting up
          </h2>
          <p className="text-xs text-muted-foreground">
            {visible.length} task{visible.length === 1 ? '' : 's'} left
          </p>
        </div>
        <button
          type="button"
          onClick={() => setCollapsed((c) => !c)}
          className="text-xs font-medium text-muted-foreground transition hover:text-foreground"
          aria-expanded={!collapsed}
        >
          {collapsed ? 'Show' : 'Hide'}
        </button>
      </header>
      {!collapsed && (
        <ul className="flex flex-col gap-3">
          {visible.map((card) => (
            <li
              key={card.key}
              className="rounded-lg border border-border bg-background p-3"
            >
              <header className="mb-2 flex items-center justify-between gap-3">
                <h3 className="text-sm font-semibold text-foreground">
                  {card.title}
                </h3>
                <button
                  type="button"
                  onClick={() => dismiss(card.key)}
                  className="text-xs text-muted-foreground transition hover:text-foreground"
                  aria-label={`Dismiss ${card.title}`}
                >
                  Done
                </button>
              </header>
              <div className="space-y-2 text-sm text-foreground">{card.body}</div>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
