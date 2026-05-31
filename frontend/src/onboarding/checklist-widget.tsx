import { useState } from 'react'
import { useOnboardingActions } from './use-onboarding-actions'
import { Button } from '../components/ui/button'

interface Props {
  onStartTour: () => void
}

interface Item {
  key: string
  label: string
  done: boolean
  cta?: () => void
  ctaLabel?: string
  comingSoon?: boolean
}

export function ChecklistWidget({ onStartTour }: Props) {
  const [collapsed, setCollapsed] = useState(false)
  const ob = useOnboardingActions()

  if (ob.isLoading) return null

  const items: Item[] = [
    {
      key: 'vault',
      label: 'Create your first vault',
      done: ob.has('first_vault_created'),
    },
    {
      key: 'plugin',
      label: 'Install the Obsidian plugin',
      done: ob.has('plugin_connected'),
      ctaLabel: 'Get plugin',
      cta: () => window.open('https://app.engram.page/device-link', '_self'),
    },
    ...(ob.has('tour_offered_skipped') && !ob.has('tour_completed')
      ? [
          {
            key: 'tour',
            label: 'Take the tour',
            done: false,
            ctaLabel: 'Start',
            cta: onStartTour,
          } as Item,
        ]
      : []),
    {
      key: 'ai',
      label: 'Connect AI (coming soon)',
      done: false,
      comingSoon: true,
    },
  ]

  const allDone = items.every((i) => i.done || i.comingSoon)
  if (allDone) return null

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
        {items.map((i) => (
          <li
            key={i.key}
            className="flex items-center justify-between gap-2 text-sm"
          >
            <span
              className={`flex items-center gap-2 ${i.comingSoon ? 'opacity-50' : ''}`}
            >
              <span aria-hidden>{i.done ? '✅' : '☐'}</span>
              {i.label}
            </span>
            {i.cta && !i.done && (
              <Button size="sm" variant="outline" onClick={i.cta}>
                {i.ctaLabel}
              </Button>
            )}
          </li>
        ))}
      </ul>
    </section>
  )
}
