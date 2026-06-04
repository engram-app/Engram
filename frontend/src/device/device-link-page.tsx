import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useAuthAdapter } from '../auth/use-auth-adapter'
import { useNavigate } from 'react-router'
import { api } from '../api/client'
import { setActiveVaultId } from '../api/active-vault'
import AuthShell from '../layout/auth-shell'
import AuthPanel from '../layout/auth-panel'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { heading, fieldInput, destructiveAlert } from '@/lib/ui-classes'

type Vault = { id: number; name: string; note_count: number }

type Step = 'enter-code' | 'pick-vault' | 'success' | 'error'

export default function DeviceLinkPage() {
  const { isSignedIn } = useAuthAdapter()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [step, setStep] = useState<Step>('enter-code')
  const [userCode, setUserCode] = useState('')
  const [vaults, setVaults] = useState<Vault[]>([])
  // `selection` doubles as the dropdown value: 'new' for create-new, or the
  // existing vault id stringified (HTML <select> values are strings).
  const [selection, setSelection] = useState<string>('new')
  const [suggestedName, setSuggestedName] = useState('')
  const [customName, setCustomName] = useState('')
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
      setSuggestedName(data.suggested_vault_name?.trim() || '')
      // Default selection: always start on "create new" so the matched
      // Obsidian name leads. Users with existing vaults can pick one explicitly.
      setSelection('new')
      setStep('pick-vault')
    } catch {
      setError('Failed to load vaults. Please try again.')
    } finally {
      setLoading(false)
    }
  }

  const createNew = selection === 'new'
  const effectiveNewName = (customName.trim() || suggestedName || '').trim()

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
      // Forward to the vault that was just linked — not whatever the vault
      // switcher would otherwise fall back to (the default / first vault).
      setActiveVaultId(vault_id)
      qc.invalidateQueries({ queryKey: ['vaults'] })
      setStep('success')
      setTimeout(() => navigate('/'), 1500)
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

  const canAuthorize = createNew ? effectiveNewName.length > 0 : selection !== 'new'

  return (
    <AuthShell>
      <AuthPanel className="flex flex-col gap-4">
        <h1 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
          Link Obsidian Vault
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
              Code verified. Pick where these notes should sync:
            </p>

            <label className="flex flex-col gap-2 text-sm">
              <span className="font-medium text-foreground">Sync target</span>
              <select
                value={selection}
                onChange={(e) => setSelection(e.target.value)}
                className={fieldInput}
              >
                <option value="new">
                  {suggestedName
                    ? `${suggestedName} (Match Obsidian vault name)`
                    : 'Create a new vault'}
                </option>
                {vaults.map((v) => (
                  <option key={v.id} value={String(v.id)}>
                    {v.name} ({v.note_count} notes)
                  </option>
                ))}
              </select>
            </label>

            {createNew && (
              <label className="flex flex-col gap-2 text-sm">
                <span className="font-medium text-foreground">
                  Use a different name (optional)
                </span>
                <input
                  type="text"
                  value={customName}
                  onChange={(e) => setCustomName(e.target.value)}
                  placeholder="choose new name"
                  maxLength={100}
                  className={fieldInput}
                />
              </label>
            )}

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
          <div className="flex flex-col gap-2">
            <h2 className="text-lg font-semibold text-foreground">Vault linked!</h2>
            <p className="text-sm text-muted-foreground">
              Your Obsidian plugin is now connected. Redirecting to your vault…
            </p>
          </div>
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
