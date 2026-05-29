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
  const [selectedVaultId, setSelectedVaultId] = useState<number | null>(null)
  const [newVaultName, setNewVaultName] = useState('')
  const [createNew, setCreateNew] = useState(false)
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
      const data = await api.get<{ vaults: Vault[] }>('/vaults')
      const formattedCode = formatted.slice(0, 4) + '-' + formatted.slice(4)
      setUserCode(formattedCode)
      setVaults(data.vaults ?? [])
      if (!data.vaults || data.vaults.length === 0) {
        setCreateNew(true)
      }
      setStep('pick-vault')
    } catch {
      setError('Failed to load vaults. Please try again.')
    } finally {
      setLoading(false)
    }
  }

  async function handleAuthorize() {
    setLoading(true)
    setError('')
    try {
      const body = createNew
        ? { user_code: userCode, vault_id: 'new', vault_name: newVaultName }
        : { user_code: userCode, vault_id: selectedVaultId }

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

  const canAuthorize = createNew ? newVaultName.trim().length > 0 : selectedVaultId !== null

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
              {vaults.length > 0
                ? 'Code verified. Choose which vault to sync:'
                : 'Code verified. Create a vault to get started:'}
            </p>
            <fieldset className="flex flex-col gap-2">
              {vaults.map((v) => {
                const active = !createNew && selectedVaultId === v.id
                return (
                  <label
                    key={v.id}
                    className={selectableRow(active)}
                  >
                    <input
                      type="radio"
                      name="vault"
                      checked={active}
                      onChange={() => {
                        setSelectedVaultId(v.id)
                        setCreateNew(false)
                      }}
                      className="accent-primary"
                    />
                    <span className="text-sm font-medium text-foreground">
                      {v.name}{' '}
                      <span className="font-normal text-muted-foreground">
                        ({v.note_count} notes)
                      </span>
                    </span>
                  </label>
                )
              })}
              {vaults.length > 0 && (
                <label
                  className={selectableRow(createNew)}
                >
                  <input
                    type="radio"
                    name="vault"
                    checked={createNew}
                    onChange={() => {
                      setCreateNew(true)
                      setSelectedVaultId(null)
                    }}
                    className="accent-primary"
                  />
                  <span className="text-sm font-medium text-foreground">+ Create new vault</span>
                </label>
              )}
            </fieldset>

            {createNew && (
              <input
                type="text"
                value={newVaultName}
                onChange={(e) => setNewVaultName(e.target.value)}
                placeholder="Vault name"
                className={fieldInput}
              />
            )}

            <Button
              type="button"
              onClick={handleAuthorize}
              disabled={loading || !canAuthorize}
              className="w-full"
            >
              {loading ? 'Authorizing…' : 'Authorize'}
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
