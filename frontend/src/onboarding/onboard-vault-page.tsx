import { useEffect, useState } from 'react'
import { Navigate, useLocation, useNavigate } from 'react-router'
import { setActiveVaultId } from '../api/active-vault'
import {
  useCreateVault,
  useMe,
  useOnboardingStatus,
  useUpdateNote,
} from '../api/queries'
import AuthPanel from '@/layout/auth-panel'
import LoadingScreen from '../layout/loading-screen'
import { heading } from '@/lib/ui-classes'
import { useVaultReadyEvents } from './use-vault-ready-events'
import { WELCOME_NOTE_CONTENT, WELCOME_NOTE_PATH } from './welcome-note'

type View = 'obsidian' | 'fresh'

export default function OnboardVaultPage() {
  const navigate = useNavigate()
  const location = useLocation()
  const { data: status, isLoading } = useOnboardingStatus()
  const { data: me } = useMe()
  const createVault = useCreateVault()
  const updateNote = useUpdateNote()

  // Allow the user to override their original answer ("or skip — name a
  // vault here instead"). `null` = follow whatever the profile said.
  const [override, setOverride] = useState<View | null>(null)

  // Block render until status arrives so the obsidian user never briefly
  // sees the fresh-path form before the page flips to install instructions.
  if (isLoading || !status) {
    return <LoadingScreen />
  }

  // Page can be reached by direct URL or a stale tab — make sure the user
  // is actually at the vault step. Redirect back to whatever step the
  // server thinks they're on. Without this, a user with an empty profile
  // landing here from a refresh would see the fresh-path form even though
  // they haven't answered the questionnaire yet.
  if (status.next_step !== 'vault' && status.next_step !== 'done') {
    return <RedirectToNextStep step={status.next_step} />
  }
  if (status.next_step === 'done') {
    return <RedirectToDashboard />
  }

  // Source of truth, in priority order:
  // 1. User override (clicked "or skip" to switch to fresh)
  // 2. Router state from the questionnaire submit — deterministic, no
  //    race on the status query refetch
  // 3. Status query (covers deep-link / page-refresh cases)
  const stateUsesObsidian = (location.state as { usesObsidian?: boolean } | null)
    ?.usesObsidian
  const profileUsesObsidian =
    stateUsesObsidian ?? status.profile?.uses_obsidian === true
  const view: View = override ?? (profileUsesObsidian ? 'obsidian' : 'fresh')

  if (view === 'obsidian') {
    return (
      <ObsidianView
        userId={me?.id ?? null}
        onSwitchToFresh={() => setOverride('fresh')}
        onSkipToDashboard={() => navigate('/', { replace: true })}
      />
    )
  }

  return (
    <FreshView
      isPending={createVault.isPending || updateNote.isPending}
      onCreate={async (name) => {
        const trimmed = name.trim() || 'My Vault'
        const { vault } = await createVault.mutateAsync({ name: trimmed })
        setActiveVaultId(vault.id)
        try {
          await updateNote.mutateAsync({
            path: WELCOME_NOTE_PATH,
            content: WELCOME_NOTE_CONTENT,
          })
        } catch {
          // Vault still exists if note-seed fails — let the user proceed.
        }
        navigate('/', { replace: true })
      }}
    />
  )
}

function RedirectToNextStep({ step }: { step: string }) {
  return <Navigate to={`/onboard/${step}`} replace />
}

function RedirectToDashboard() {
  return <Navigate to="/" replace />
}

// ── Obsidian path ─────────────────────────────────────────────────────────────

interface ObsidianViewProps {
  userId: number | null
  onSwitchToFresh: () => void
  onSkipToDashboard: () => void
}

function ObsidianView({ userId, onSwitchToFresh, onSkipToDashboard }: ObsidianViewProps) {
  const navigate = useNavigate()
  const { vaultCreated, vaultPopulated, vaultId } = useVaultReadyEvents({
    userId,
    enabled: true,
  })

  // Auto-transition once the plugin has actually written notes. Setting the
  // active vault makes the dashboard open into the new vault directly
  // instead of falling through CreateFirstVaultModal.
  useEffect(() => {
    if (vaultPopulated && vaultId != null) {
      setActiveVaultId(vaultId)
      navigate('/', { replace: true })
    }
  }, [vaultPopulated, vaultId, navigate])

  const stage: 'waiting' | 'detected' | 'syncing' = vaultPopulated
    ? 'syncing'
    : vaultCreated
      ? 'detected'
      : 'waiting'

  return (
    <AuthPanel className="flex flex-col gap-5">
      <header className="flex flex-col gap-2">
        <h1 className={heading}>Install the Engram plugin</h1>
        <p className="text-sm text-muted-foreground">
          Three steps. We'll wait on this page until your vault appears here —
          no need to come back.
        </p>
      </header>

      <ol className="flex list-decimal flex-col gap-3 pl-5 text-sm text-foreground">
        <li>
          Open Obsidian → <strong>Settings → Community plugins → Browse</strong>,
          search for <em>Engram</em>, install and enable it.
        </li>
        <li>
          Inside the plugin, click <strong>Sign in</strong> and authenticate
          with your Engram account.
        </li>
        <li>
          Pick a vault to sync. The plugin will create a matching Engram
          vault and push your existing files.
        </li>
      </ol>

      <StatusRow stage={stage} />

      <footer className="flex flex-col gap-2 border-t border-border pt-4 text-sm">
        <button
          type="button"
          onClick={onSkipToDashboard}
          className="rounded-lg border border-border bg-background px-4 py-2 font-medium text-foreground transition hover:bg-accent/40"
        >
          I've installed it — take me to my dashboard
        </button>
        <button
          type="button"
          onClick={onSwitchToFresh}
          className="text-xs font-medium text-muted-foreground transition hover:text-foreground"
        >
          Or skip — name a vault here instead
        </button>
      </footer>
    </AuthPanel>
  )
}

function StatusRow({ stage }: { stage: 'waiting' | 'detected' | 'syncing' }) {
  const labels: Record<typeof stage, string> = {
    waiting: 'Waiting for the plugin to sign in…',
    detected: 'Vault detected. Waiting for your first sync…',
    syncing: 'Syncing your notes — almost there…',
  }
  return (
    <p
      role="status"
      aria-live="polite"
      className="rounded-md border border-dashed border-border bg-muted/40 px-3 py-2 text-sm text-muted-foreground"
    >
      <span className="mr-2 inline-block size-2 animate-pulse rounded-full bg-primary align-middle" />
      {labels[stage]}
    </p>
  )
}

// ── Fresh-start path ──────────────────────────────────────────────────────────

interface FreshViewProps {
  isPending: boolean
  onCreate: (name: string) => Promise<void>
}

function FreshView({ isPending, onCreate }: FreshViewProps) {
  const [name, setName] = useState('My Vault')
  const [error, setError] = useState<string | null>(null)

  async function submit() {
    setError(null)
    try {
      await onCreate(name)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not create vault')
    }
  }

  const disabled = isPending || name.trim().length === 0

  return (
    <AuthPanel className="flex flex-col gap-5">
      <header className="flex flex-col gap-2">
        <h1 className={heading}>Name your first vault</h1>
        <p className="text-sm text-muted-foreground">
          A vault is a folder for related notes. We'll create one with a
          welcome note so the editor isn't empty when you arrive. You can
          rename or add more later from settings.
        </p>
      </header>

      <label className="flex flex-col gap-2 text-sm">
        <span className="font-medium text-foreground">Vault name</span>
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          autoFocus
          maxLength={100}
          className="rounded-lg border border-border bg-background px-3 py-2 text-base text-foreground outline-none focus:border-primary focus:ring-2 focus:ring-primary/30"
        />
      </label>

      {error ? (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      ) : null}

      <button
        type="button"
        onClick={submit}
        disabled={disabled}
        className="w-full rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
      >
        {isPending ? 'Creating…' : 'Create vault & continue'}
      </button>
    </AuthPanel>
  )
}
