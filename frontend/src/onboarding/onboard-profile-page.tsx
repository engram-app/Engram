import { useState } from 'react'
import { useNavigate } from 'react-router'
import { useSetOnboardingProfile } from '../api/queries'
import { Checkbox } from '@/components/ui/checkbox'
import AuthPanel from '@/layout/auth-panel'
import { heading, selectableRow } from '@/lib/ui-classes'
import { TOOL_APPS, TOOL_DEV, type ToolOption } from './onboarding-tools'

type Screen = 'obsidian' | 'tools'

export default function OnboardProfilePage() {
  const navigate = useNavigate()
  const { mutateAsync, isPending, error } = useSetOnboardingProfile()
  const [screen, setScreen] = useState<Screen>('obsidian')
  const [usesObsidian, setUsesObsidian] = useState<boolean | null>(null)
  const [tools, setTools] = useState<Set<string>>(new Set())

  function toggleTool(slug: string) {
    setTools((prev) => {
      const next = new Set(prev)
      next.has(slug) ? next.delete(slug) : next.add(slug)
      return next
    })
  }

  function pickObsidian(value: boolean) {
    setUsesObsidian(value)
    setScreen('tools')
  }

  async function submit() {
    if (usesObsidian == null || tools.size === 0) return
    await mutateAsync({ uses_obsidian: usesObsidian, tools: Array.from(tools) })
    // Always route to the vault step (Step 4). Obsidian users see install
    // instructions + socket-driven wait; fresh users name their vault.
    // Thread the just-picked answer via router state so the vault page
    // renders the correct variant on first paint without racing on the
    // ['onboarding','status'] cache refetch.
    navigate('/onboard/vault', {
      replace: true,
      state: { usesObsidian },
    })
  }

  if (screen === 'obsidian') {
    return (
      <AuthPanel className="flex flex-col gap-6">
        <header className="flex flex-col gap-2">
          <h1 className={heading}>Where do your notes live?</h1>
          <p className="text-sm text-muted-foreground">
            Engram stores your notes as plain markdown files. Obsidian is one
            way to read them — not required. Let us know what you have today
            so we can skip the steps you don't need.
          </p>
        </header>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <ChoiceCard
            title="I already use Obsidian"
            body="Install our plugin next and your first sync creates the vault — no empty placeholder."
            onClick={() => pickObsidian(true)}
          />
          <ChoiceCard
            title="I'm starting fresh"
            body="We'll create your first vault now. You can change its name later."
            onClick={() => pickObsidian(false)}
          />
        </div>
      </AuthPanel>
    )
  }

  const canContinue = tools.size > 0 && !isPending

  return (
    <AuthPanel className="flex flex-col gap-6">
      <header className="flex flex-col gap-2">
        <h1 className={heading}>How will you use Engram?</h1>
        <p className="text-sm text-muted-foreground">
          Pick everything that applies. We'll show you the exact setup steps
          for each one on your dashboard. You can update this any time from
          settings.
        </p>
      </header>
      <div className="grid grid-cols-1 gap-6 sm:grid-cols-2">
        <ToolColumn title="Apps" options={TOOL_APPS} selected={tools} onToggle={toggleTool} />
        <ToolColumn title="Dev tools" options={TOOL_DEV} selected={tools} onToggle={toggleTool} />
      </div>
      {error ? (
        <p role="alert" className="text-sm text-destructive">
          Couldn't save your answers — please try again.
        </p>
      ) : null}
      <div className="flex items-center justify-between gap-2">
        <button
          type="button"
          onClick={() => setScreen('obsidian')}
          className="text-sm font-medium text-muted-foreground transition hover:text-foreground"
        >
          ← Back
        </button>
        <button
          type="button"
          onClick={submit}
          disabled={!canContinue}
          className="rounded-lg bg-primary px-6 py-2 text-sm font-medium text-primary-foreground transition hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {isPending ? 'Saving…' : 'Continue'}
        </button>
      </div>
    </AuthPanel>
  )
}

interface ChoiceCardProps {
  title: string
  body: string
  onClick: () => void
}

function ChoiceCard({ title, body, onClick }: ChoiceCardProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="group flex flex-col gap-2 rounded-xl border border-border bg-background p-5 text-left transition hover:border-primary hover:bg-accent/30"
    >
      <span className="text-base font-semibold text-foreground group-hover:text-primary">
        {title}
      </span>
      <span className="text-sm text-muted-foreground">{body}</span>
    </button>
  )
}

interface ToolColumnProps {
  title: string
  options: ToolOption[]
  selected: Set<string>
  onToggle: (slug: string) => void
}

function ToolColumn({ title, options, selected, onToggle }: ToolColumnProps) {
  return (
    <fieldset className="flex flex-col gap-2">
      <legend className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
        {title}
      </legend>
      {options.map((opt) => (
        <label key={opt.slug} className={selectableRow(selected.has(opt.slug))}>
          <Checkbox
            checked={selected.has(opt.slug)}
            onCheckedChange={() => onToggle(opt.slug)}
            aria-label={opt.label}
          />
          <span className="text-sm font-medium text-foreground">{opt.label}</span>
        </label>
      ))}
    </fieldset>
  )
}
