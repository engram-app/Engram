import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useOnboardingActions } from './use-onboarding-actions'
import { useConnections, useOnboardingStatus, type OnboardingStatus } from '../api/queries'
import { Button } from '../components/ui/button'

interface Props {
  onStartTour: () => void
}

interface Item {
  key: string
  label: string
  done: boolean
  docUrl?: string
  startTour?: () => void
  dismissible?: boolean
}

const DOC_URLS: Record<string, string> = {
  install_obsidian_plugin: 'https://engram.page/docs/obsidian/install/',
  claude:         'https://engram.page/docs/integrations/claude-desktop/',
  cursor:         'https://engram.page/docs/integrations/cursor/',
  claude_code:    'https://engram.page/docs/integrations/claude-code/',
  chatgpt:        'https://engram.page/docs/integrations/chatgpt/',
  grok:           'https://engram.page/docs/integrations/grok/',
  mistral:        'https://engram.page/docs/integrations/mistral/',
  open_webui:     'https://engram.page/docs/integrations/open-webui/',
  lobechat:       'https://engram.page/docs/integrations/lobechat/',
  windsurf:       'https://engram.page/docs/integrations/windsurf/',
  cline:          'https://engram.page/docs/integrations/cline/',
  continue:       'https://engram.page/docs/integrations/continue/',
  opencode:       'https://engram.page/docs/integrations/opencode/',
  github_copilot: 'https://engram.page/docs/integrations/github-copilot/',
  other_mcp:      'https://engram.page/docs/mcp/manual-config/',
}
const DOC_FALLBACK = 'https://engram.page/docs/integrations/'

const TOOL_LABELS: Record<string, string> = {
  claude:         'Connect Claude Desktop',
  cursor:         'Connect Cursor',
  claude_code:    'Connect Claude Code',
  chatgpt:        'Connect ChatGPT',
  grok:           'Connect Grok',
  mistral:        'Connect Mistral',
  open_webui:     'Connect Open WebUI',
  lobechat:       'Connect LobeChat',
  windsurf:       'Connect Windsurf',
  cline:          'Connect Cline',
  continue:       'Connect Continue',
  opencode:       'Connect OpenCode',
  github_copilot: 'Connect GitHub Copilot',
  other_mcp:      'Connect another MCP client',
}

export function ChecklistWidget({ onStartTour }: Props) {
  const [collapsed, setCollapsed] = useState(false)
  const ob = useOnboardingActions()
  const status = useOnboardingStatus()
  const connections = useConnections()
  const qc = useQueryClient()

  if (ob.isLoading) return null

  const actions = status.data?.actions ?? []
  const dismissed = new Set(
    actions
      .filter((a): a is `dismissed:${string}` => a.startsWith('dismissed:'))
      .map((a) => a.slice('dismissed:'.length)),
  )

  function dismiss(key: string) {
    const action = `dismissed:${key}` as const

    // Optimistic cache update so the row vanishes immediately without
    // waiting for the mutation to round-trip. The mutation's onSuccess
    // invalidates this query, so the cache will be normalized from server.
    qc.setQueryData<OnboardingStatus>(['onboarding', 'status'], (prev) => {
      if (!prev) return prev
      if (prev.actions.includes(action)) return prev
      return { ...prev, actions: [...prev.actions, action] }
    })

    void ob.recordAsync(action).catch(() => {
      // The mutation hook already retries 3× — reaching here means the
      // server rejected. Roll back by invalidating so the next refetch
      // restores the real cache state.
      qc.invalidateQueries({ queryKey: ['onboarding', 'status'] })
    })
  }

  const profile = status.data?.profile
  const tools = (profile?.tools ?? []).filter((t) => t !== 'web_only')
  const isDismissed = (key: string) => dismissed.has(key)
  const hasObsidianConnection = (connections.data ?? []).some((c) => c.kind === 'obsidian')

  const items: Item[] = [
    {
      key: 'vault',
      label: 'Create your first vault',
      done: ob.has('first_vault_created'),
    },
    ...(profile?.uses_obsidian
      ? [
          {
            key: 'install_obsidian_plugin',
            label: 'Install the Obsidian plugin',
            done: hasObsidianConnection || isDismissed('install_obsidian_plugin'),
            docUrl: DOC_URLS.install_obsidian_plugin,
            dismissible: true,
          } as Item,
        ]
      : []),
    ...(!ob.has('tour_completed') && !isDismissed('tour')
      ? [
          {
            key: 'tour',
            label: 'Take the tour',
            done: false,
            startTour: onStartTour,
            dismissible: true,
          } as Item,
        ]
      : []),
    ...tools.map(
      (slug): Item => ({
        key: slug,
        label: TOOL_LABELS[slug] ?? `Connect ${slug}`,
        done: isDismissed(slug),
        docUrl: DOC_URLS[slug] ?? DOC_FALLBACK,
        dismissible: true,
      }),
    ),
  ]

  const visible = items.filter((i) => !i.done)

  if (visible.length === 0) return null

  if (collapsed) {
    return (
      <button
        type="button"
        aria-label="Open onboarding checklist"
        className="fixed bottom-4 right-4 z-40 h-12 w-12 rounded-full bg-primary text-primary-foreground shadow-lg hover:bg-primary/80"
        onClick={() => setCollapsed(false)}
      >
        ✓
      </button>
    )
  }

  return (
    <section
      aria-label="Onboarding checklist"
      className="fixed bottom-4 right-4 z-40 w-80 rounded-lg border border-border bg-background shadow-lg"
    >
      <header className="flex flex-row items-center justify-between px-4 py-3 border-b border-border">
        <h2 className="text-base font-semibold">Get started</h2>
        <button
          type="button"
          aria-label="Dismiss checklist"
          className="rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
          onClick={() => setCollapsed(true)}
        >
          ×
        </button>
      </header>
      <ul className="flex flex-col gap-2 p-4">
        {visible.map((i) => (
          <li
            key={i.key}
            className="flex items-center justify-between gap-2 text-sm"
          >
            <span className="flex items-center gap-2">
              <span aria-hidden>☐</span>
              {i.label}
            </span>
            <span className="flex items-center gap-1">
              {i.startTour ? (
                <Button size="sm" variant="outline" onClick={i.startTour}>
                  Start
                </Button>
              ) : i.docUrl ? (
                <Button asChild size="sm" variant="outline">
                  <a href={i.docUrl} target="_blank" rel="noreferrer">
                    Setup guide ↗
                  </a>
                </Button>
              ) : null}
              {i.dismissible && (
                <button
                  type="button"
                  aria-label={`Dismiss ${i.label}`}
                  className="rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
                  onClick={() => dismiss(i.key)}
                >
                  ×
                </button>
              )}
            </span>
          </li>
        ))}
      </ul>
    </section>
  )
}
