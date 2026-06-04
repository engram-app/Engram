import { useEffect, useState } from 'react'
import { Navigate, useNavigate } from 'react-router'
import { setActiveVaultId } from '../api/active-vault'
import {
  useCreateVault,
  useMe,
  useOnboardingStatus,
  useSetOnboardingProfile,
  useUpdateNote,
} from '../api/queries'
import AuthPanel from '@/layout/auth-panel'
import LoadingScreen from '../layout/loading-screen'
import { heading } from '@/lib/ui-classes'
import { useVaultReadyEvents } from './use-vault-ready-events'
import { WELCOME_NOTE_CONTENT, WELCOME_NOTE_PATH } from './welcome-note'

type Source = 'obsidian' | 'fresh' | null

export default function OnboardVaultPage() {
  const navigate = useNavigate()
  const { data: status, isLoading } = useOnboardingStatus()
  const { data: me } = useMe()
  const setProfile = useSetOnboardingProfile()
  const createVault = useCreateVault()
  const updateNote = useUpdateNote()

  // Block render until status arrives so the source toggle never flashes
  // the wrong branch on first paint for a returning mid-flow user.
  if (isLoading || !status) {
    return <LoadingScreen />
  }

  // Backend owns step ordering — if it says tools/agreement/billing should
  // come first, honor that. `:done` means wizard complete; kick home.
  if (status.next_step !== 'vault' && status.next_step !== 'done') {
    return <Navigate to={`/onboard/${status.next_step}`} replace />
  }
  if (status.next_step === 'done') {
    return <Navigate to="/" replace />
  }

  return (
    <VaultStep
      profileSaved={status.profile_complete === true}
      savedUsesObsidian={status.profile?.uses_obsidian === true}
      userId={me?.id ?? null}
      setProfile={setProfile}
      createVault={createVault}
      updateNote={updateNote}
      navigate={navigate}
    />
  )
}

interface VaultStepProps {
  profileSaved: boolean
  savedUsesObsidian: boolean
  userId: number | null
  setProfile: ReturnType<typeof useSetOnboardingProfile>
  createVault: ReturnType<typeof useCreateVault>
  updateNote: ReturnType<typeof useUpdateNote>
  navigate: ReturnType<typeof useNavigate>
}

function VaultStep({
  profileSaved,
  savedUsesObsidian,
  userId,
  setProfile,
  createVault,
  updateNote,
  navigate,
}: VaultStepProps) {
  // Mid-flow refresh: if uses_obsidian was already POSTed in a prior visit,
  // pre-select that side so the user sees the inline panel for the branch
  // they picked instead of an empty source toggle.
  const [source, setSource] = useState<Source>(
    profileSaved ? (savedUsesObsidian ? 'obsidian' : 'fresh') : null,
  )

  async function commitObsidian() {
    await setProfile.mutateAsync({ uses_obsidian: true })
    navigate('/', { replace: true })
  }

  async function commitFresh(name: string) {
    await setProfile.mutateAsync({ uses_obsidian: false })
    const trimmed = name.trim() || 'My Vault'
    const { vault } = await createVault.mutateAsync({ name: trimmed })
    setActiveVaultId(vault.id)
    try {
      await updateNote.mutateAsync({
        path: WELCOME_NOTE_PATH,
        content: WELCOME_NOTE_CONTENT,
      })
    } catch {
      // Vault still exists if the welcome-note seed fails — let the user
      // proceed; an empty vault is recoverable, a missing vault is not.
    }
    navigate('/', { replace: true })
  }

  return (
    <SourceScreen
      source={source}
      onPickSource={setSource}
      userId={userId}
      isCommitting={
        setProfile.isPending || createVault.isPending || updateNote.isPending
      }
      onCommitObsidian={commitObsidian}
      onCommitFresh={commitFresh}
    />
  )
}

// ── Source screen (with inline action panel) ──────────────────────────────────

interface SourceScreenProps {
  source: Source
  onPickSource: (s: Source) => void
  userId: number | null
  isCommitting: boolean
  onCommitObsidian: () => Promise<void>
  onCommitFresh: (name: string) => Promise<void>
}

function SourceScreen({
  source,
  onPickSource,
  userId,
  isCommitting,
  onCommitObsidian,
  onCommitFresh,
}: SourceScreenProps) {
  return (
    <AuthPanel className="flex flex-col gap-6">
      <header className="flex flex-col gap-2">
        <h1 className={heading}>Where do your notes live?</h1>
        <p className="text-sm text-muted-foreground">
          Engram stores your notes as plain markdown files. Obsidian is one
          way to read them — not required. Pick a side and we'll get you set
          up right here.
        </p>
      </header>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <SourceCard
          title="I already use Obsidian"
          body="Install our plugin and your first sync creates the vault — no empty placeholder."
          selected={source === 'obsidian'}
          onClick={() => onPickSource('obsidian')}
        />
        <SourceCard
          title="I'm starting fresh"
          body="We'll create your first vault now. You can rename or add more later from settings."
          selected={source === 'fresh'}
          onClick={() => onPickSource('fresh')}
        />
      </div>

      {source === 'obsidian' ? (
        <ObsidianInlinePanel
          userId={userId}
          isCommitting={isCommitting}
          onCommit={onCommitObsidian}
        />
      ) : source === 'fresh' ? (
        <FreshInlinePanel isCommitting={isCommitting} onCommit={onCommitFresh} />
      ) : null}
    </AuthPanel>
  )
}

interface SourceCardProps {
  title: string
  body: string
  selected: boolean
  onClick: () => void
}

function SourceCard({ title, body, selected, onClick }: SourceCardProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={selected}
      className={
        'group flex flex-col gap-2 rounded-xl border p-5 text-left transition ' +
        (selected
          ? 'border-primary bg-accent/40'
          : 'border-border bg-background hover:border-primary hover:bg-accent/30')
      }
    >
      <span className="text-base font-semibold text-foreground group-hover:text-primary">
        {title}
      </span>
      <span className="text-sm text-muted-foreground">{body}</span>
    </button>
  )
}

// ── Obsidian inline panel ─────────────────────────────────────────────────────

interface ObsidianInlinePanelProps {
  userId: number | null
  isCommitting: boolean
  onCommit: () => Promise<void>
}

function ObsidianInlinePanel({ userId, isCommitting, onCommit }: ObsidianInlinePanelProps) {
  const { vaultCreated, vaultPopulated, vaultId } = useVaultReadyEvents({
    userId,
    enabled: true,
  })

  // Auto-commit + activate once the plugin has actually written notes, so
  // the user is hands-off the moment their first sync lands.
  useEffect(() => {
    if (vaultPopulated && vaultId != null && !isCommitting) {
      setActiveVaultId(vaultId)
      void onCommit()
    }
  }, [vaultPopulated, vaultId, isCommitting, onCommit])

  const stage: 'waiting' | 'detected' | 'syncing' = vaultPopulated
    ? 'syncing'
    : vaultCreated
      ? 'detected'
      : 'waiting'

  return (
    <div className="flex flex-col gap-4 rounded-xl border border-border bg-muted/30 p-5">
      <h2 className="text-base font-semibold text-foreground">
        Install the Engram plugin
      </h2>
      <ol className="flex list-decimal flex-col gap-2 pl-5 text-sm text-foreground">
        <li>
          Open Obsidian → <strong>Settings → Community plugins → Browse</strong>,
          search for <em>Engram</em>, install and enable it.
        </li>
        <li>
          Inside the plugin, click <strong>Sign in</strong> and authenticate
          with your Engram account.
        </li>
        <li>
          Pick a vault to sync. The plugin creates a matching Engram vault
          and pushes your existing files.
        </li>
      </ol>
      <StatusRow stage={stage} />
    </div>
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

// ── Fresh-start inline panel ──────────────────────────────────────────────────

interface FreshInlinePanelProps {
  isCommitting: boolean
  onCommit: (name: string) => Promise<void>
}

function FreshInlinePanel({ isCommitting, onCommit }: FreshInlinePanelProps) {
  const [name, setName] = useState('My Vault')
  const [error, setError] = useState<string | null>(null)

  async function submit() {
    setError(null)
    try {
      await onCommit(name)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not create vault')
    }
  }

  const disabled = isCommitting || name.trim().length === 0

  return (
    <div className="flex flex-col gap-4 rounded-xl border border-border bg-muted/30 p-5">
      <h2 className="text-base font-semibold text-foreground">Name your first vault</h2>
      <p className="text-sm text-muted-foreground">
        A vault is a folder for related notes. We'll seed it with a welcome
        note so the editor isn't empty when you arrive.
      </p>
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
        className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
      >
        {isCommitting ? 'Creating…' : 'Create vault & continue'}
      </button>
    </div>
  )
}
