import { useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useAuthAdapter } from '../auth/use-auth-adapter'
import { useNavigate } from 'react-router'
import { api } from '../api/client'
import { setActiveVaultId } from '../api/active-vault'
import AuthShell from '../layout/auth-shell'
import AuthPanel from '../layout/auth-panel'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { heading, fieldInput, destructiveAlert, selectableRow } from '@/lib/ui-classes'
import { useMe } from '../api/queries'
import { SyncStatusPill } from '../onboarding/sync-status-pill'
import { useVaultReadyEvents } from '../onboarding/use-vault-ready-events'

type Vault = { id: number; name: string; note_count: number }

type Step = 'enter-code' | 'pick-vault' | 'success' | 'error'

export default function DeviceLinkPage() {
  const { isSignedIn } = useAuthAdapter()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [step, setStep] = useState<Step>('enter-code')
  const [userCode, setUserCode] = useState('')
  const [vaults, setVaults] = useState<Vault[]>([])
  // `selection` is the radio-row value: 'matched' (create new with the
  // plugin-suggested name), 'custom' (create new with the input below), or
  // the existing vault id as a string.
  const [selection, setSelection] = useState<string>('matched')
  const [suggestedName, setSuggestedName] = useState('')
  const [customName, setCustomName] = useState('')
  const [linkedVaultId, setLinkedVaultId] = useState<number | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  if (!isSignedIn) {
    return (
      <AuthShell>
        <AuthPanel className="flex flex-col gap-3">
          <h1 className={heading}>
            Link Obsidian Vault
          </h1>
          <p className="text-sm text-muted-foreground">
            Please sign in to link your Obsidian vault.
          </p>
        </AuthPanel>
      </AuthShell>
    )
  }

  async function handleVerifyCode() {
    const formatted = userCode.toUpperCase().replace(/[^A-Z2-9]/g, '')
    if (formatted.length !== 8) {
      setError('Code must be 8 characters (e.g., ENGR-7X4K)')
      return
    }

    setLoading(true)
    setError('')
    try {
      const formattedCode = formatted.slice(0, 4) + '-' + formatted.slice(4)
      const data = await api.get<{ vaults: Vault[]; suggested_vault_name?: string | null }>(
        `/vaults?user_code=${encodeURIComponent(formattedCode)}`,
      )
      setUserCode(formattedCode)
      setVaults(data.vaults ?? [])
      const suggested = data.suggested_vault_name?.trim() || ''
      setSuggestedName(suggested)
      // Default selection:
      // - existing vault with the same name → pre-select that vault (link, don't dup)
      // - suggested name with no existing match → 'matched' (create new with that name)
      // - no hint at all → 'custom' (force user to type a name)
      const existing = suggested
        ? (data.vaults ?? []).find((v) => v.name === suggested)
        : undefined
      setSelection(existing ? String(existing.id) : suggested ? 'matched' : 'custom')
      setStep('pick-vault')
    } catch {
      setError('Failed to load vaults. Please try again.')
    } finally {
      setLoading(false)
    }
  }

  const isMatched = selection === 'matched'
  const isCustom = selection === 'custom'
  const createNew = isMatched || isCustom
  const effectiveNewName = isCustom
    ? customName.trim()
    : isMatched
      ? suggestedName
      : ''

  async function handleAuthorize() {
    setLoading(true)
    setError('')
    try {
      const body = createNew
        ? { user_code: userCode, vault_id: 'new', vault_name: effectiveNewName }
        : { user_code: userCode, vault_id: Number(selection) }

      const { vault_id } = await api.post<{ ok: boolean; vault_id: number }>(
        '/auth/device/authorize',
        body,
      )
      // Stash the linked vault as active so subsequent navigations land in
      // the right one. We DON'T auto-navigate immediately — the plugin still
      // owes the first sync from inside Obsidian. The success step listens
      // for the `vault_populated` broadcast and forwards then.
      setActiveVaultId(vault_id)
      setLinkedVaultId(vault_id)
      qc.invalidateQueries({ queryKey: ['vaults'] })
      setStep('success')
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : 'Authorization failed'
      if (message.includes('404') || message.includes('not found')) {
        setError('This code is invalid or has expired. Please try again from Obsidian.')
      } else {
        setError(message)
      }
    } finally {
      setLoading(false)
    }
  }

  const canAuthorize = createNew ? effectiveNewName.length > 0 : true

  return (
    <AuthShell>
      <AuthPanel
        className={cn(
          'flex flex-col gap-4',
          // pick-vault is a tighter, decision-focused step — narrow the
          // whole card so the radio rows + button don't feel oceanic.
          step === 'pick-vault' && 'mx-auto sm:w-4/5',
        )}
      >
        <h1 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
          {step === 'pick-vault' ? 'Choose a vault to sync' : 'Link Obsidian Vault'}
        </h1>

        {step === 'enter-code' && (
          <div className="flex flex-col gap-3">
            <p className="text-sm text-muted-foreground">
              Enter the code shown in your Obsidian plugin:
            </p>
            <input
              type="text"
              value={userCode}
              onChange={(e) => setUserCode(e.target.value.toUpperCase())}
              placeholder="XXXX-XXXX"
              maxLength={9}
              className={cn(fieldInput, 'text-center font-mono text-2xl tracking-widest')}
              onKeyDown={(e) => e.key === 'Enter' && handleVerifyCode()}
            />
            <Button type="button" onClick={handleVerifyCode} disabled={loading} className="w-full">
              {loading ? 'Verifying…' : 'Verify'}
            </Button>
          </div>
        )}

        {step === 'pick-vault' && (
          <div className="flex flex-col gap-3">
            <p className="text-sm text-muted-foreground">
              Pick an existing one, or create a new vault for these notes.
            </p>

            <VaultPickerFieldset
              vaults={vaults}
              suggestedName={suggestedName}
              selection={selection}
              onSelect={setSelection}
              customName={customName}
              onCustomChange={setCustomName}
            />

            <Button
              type="button"
              onClick={handleAuthorize}
              disabled={loading || !canAuthorize}
              className="w-full"
            >
              {loading ? 'Syncing…' : 'Sync'}
            </Button>
          </div>
        )}

        {step === 'success' && (
          <SuccessStep
            linkedVaultId={linkedVaultId}
            onForward={() => navigate('/')}
          />
        )}

        {error && (
          <p
            role="alert"
            className={cn(destructiveAlert, 'p-3 text-foreground')}
          >
            {error}
          </p>
        )}
      </AuthPanel>
    </AuthShell>
  )
}

interface SuccessStepProps {
  linkedVaultId: number | null
  onForward: () => void
}

function SuccessStep({ linkedVaultId, onForward }: SuccessStepProps) {
  const { data: me } = useMe()
  const { vaultPopulated, vaultId } = useVaultReadyEvents({
    userId: me?.id ?? null,
    enabled: true,
  })

  // Auto-forward to the dashboard once the plugin's first sync lands. Match
  // on `linkedVaultId` so we only forward for THIS link session — broadcasts
  // from an unrelated vault won't shove us anywhere.
  useEffect(() => {
    if (vaultPopulated && vaultId != null && vaultId === linkedVaultId) {
      onForward()
    }
  }, [vaultPopulated, vaultId, linkedVaultId, onForward])

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <h2 className="text-lg font-semibold text-foreground">Vault linked!</h2>
        <p className="text-sm text-foreground">
          Now jump back to Obsidian and run your first sync.
        </p>
      </div>

      <SyncStatusPill message="Waiting for your first sync…" />

      <p className="text-sm text-muted-foreground">
        Once it lands we'll take you to your vault automatically.
      </p>

      <Button
        type="button"
        variant="ghost"
        onClick={onForward}
        className="self-start text-sm"
      >
        Skip ahead
      </Button>
    </div>
  )
}

interface VaultPickerFieldsetProps {
  vaults: Vault[]
  suggestedName: string
  selection: string
  onSelect: (next: string) => void
  customName: string
  onCustomChange: (next: string) => void
}

// Stacked-radio picker for the /link consent page. Three row variants:
//   1. Existing vault whose name matches the plugin's suggestion (top, if any)
//      — selecting it links into that vault, no creation.
//   2. Each other existing vault — explicit link target.
//   3. Custom-name row at the bottom with an inline input — focus or type
//      to auto-select.
// If no match-by-name exists and the plugin sent a suggestion, slot a
// "create with matched name" row at the top instead.
function VaultPickerFieldset({
  vaults,
  suggestedName,
  selection,
  onSelect,
  customName,
  onCustomChange,
}: VaultPickerFieldsetProps) {
  const matchedExisting = suggestedName
    ? vaults.find((v) => v.name === suggestedName)
    : undefined
  const otherVaults = matchedExisting
    ? vaults.filter((v) => v.id !== matchedExisting.id)
    : vaults
  const isMatched = selection === 'matched'
  const isCustom = selection === 'custom'

  return (
    <fieldset className="flex flex-col gap-2">
      {matchedExisting ? (
        <label className={selectableRow(selection === String(matchedExisting.id))}>
          <input
            type="radio"
            name="vault-target"
            checked={selection === String(matchedExisting.id)}
            onChange={() => onSelect(String(matchedExisting.id))}
            className="accent-primary"
          />
          <span className="flex flex-col">
            <span className="text-sm font-medium text-foreground">
              {matchedExisting.name}
            </span>
            <span className="text-xs text-muted-foreground">
              Sync into your existing vault &middot; {matchedExisting.note_count} notes
            </span>
          </span>
        </label>
      ) : (
        suggestedName && (
          <label className={selectableRow(isMatched)}>
            <input
              type="radio"
              name="vault-target"
              checked={isMatched}
              onChange={() => onSelect('matched')}
              className="accent-primary"
            />
            <span className="flex flex-col">
              <span className="text-sm font-medium text-foreground">{suggestedName}</span>
              <span className="text-xs text-muted-foreground">
                Makes a new vault matching your Obsidian vault name
              </span>
            </span>
          </label>
        )
      )}

      {otherVaults.map((v) => {
        const active = selection === String(v.id)
        return (
          <label key={v.id} className={selectableRow(active)}>
            <input
              type="radio"
              name="vault-target"
              checked={active}
              onChange={() => onSelect(String(v.id))}
              className="accent-primary"
            />
            <span className="flex flex-col">
              <span className="text-sm font-medium text-foreground">{v.name}</span>
              <span className="text-xs text-muted-foreground">
                Sync into this existing vault &middot; {v.note_count} notes
              </span>
            </span>
          </label>
        )
      })}

      <label className={selectableRow(isCustom)}>
        <input
          type="radio"
          name="vault-target"
          checked={isCustom}
          onChange={() => onSelect('custom')}
          className="accent-primary"
        />
        <span className="flex flex-1 flex-col gap-2">
          <span className="text-sm font-medium text-foreground">
            Create a vault with a custom name
          </span>
          <input
            type="text"
            value={customName}
            onChange={(e) => {
              onCustomChange(e.target.value)
              if (!isCustom) onSelect('custom')
            }}
            onFocus={() => onSelect('custom')}
            placeholder="choose a new name"
            maxLength={100}
            className={fieldInput}
          />
        </span>
      </label>
    </fieldset>
  )
}
