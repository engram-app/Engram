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
import { heading, fieldInput, destructiveAlert, selectableRow } from '@/lib/ui-classes'

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
      // Default to the matched-name row when the plugin sent a hint;
      // otherwise drop straight to the custom-name input.
      setSelection(suggested ? 'matched' : 'custom')
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

  const canAuthorize = createNew ? effectiveNewName.length > 0 : true

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

            <fieldset className="flex flex-col gap-2">
              {suggestedName && (
                <label className={selectableRow(isMatched)}>
                  <input
                    type="radio"
                    name="vault-target"
                    checked={isMatched}
                    onChange={() => setSelection('matched')}
                    className="accent-primary"
                  />
                  <span className="flex flex-col">
                    <span className="text-sm font-medium text-foreground">
                      &ldquo;{suggestedName}&rdquo;
                    </span>
                    <span className="text-xs text-muted-foreground">
                      Makes a new vault matching your Obsidian vault name
                    </span>
                  </span>
                </label>
              )}

              {vaults.map((v) => {
                const active = selection === String(v.id)
                return (
                  <label key={v.id} className={selectableRow(active)}>
                    <input
                      type="radio"
                      name="vault-target"
                      checked={active}
                      onChange={() => setSelection(String(v.id))}
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
                  onChange={() => setSelection('custom')}
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
                      setCustomName(e.target.value)
                      if (!isCustom) setSelection('custom')
                    }}
                    onFocus={() => setSelection('custom')}
                    placeholder="choose a new name"
                    maxLength={100}
                    className={fieldInput}
                  />
                </span>
              </label>
            </fieldset>

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
