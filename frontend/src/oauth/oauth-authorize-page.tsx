import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router'
import { useQuery } from '@tanstack/react-query'
import {
  fetchOAuthClient,
  postOAuthConsent,
  type OAuthConsentParams,
} from '../api/oauth'
import { useVaults, useMe } from '../api/queries'
import AuthShell from '../layout/auth-shell'
import AuthPanel from '../layout/auth-panel'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { heading, destructiveAlert, selectableRow } from '@/lib/ui-classes'

const REQUIRED_PARAMS = [
  'client_id',
  'redirect_uri',
  'response_type',
  'code_challenge',
  'code_challenge_method',
  'state',
  'scope',
] as const

type RequiredParam = (typeof REQUIRED_PARAMS)[number]

function readParams(search: URLSearchParams): {
  values: Record<RequiredParam, string>
  resource: string | null
  missing: RequiredParam[]
} {
  const values = {} as Record<RequiredParam, string>
  const missing: RequiredParam[] = []

  for (const key of REQUIRED_PARAMS) {
    const v = search.get(key)
    if (!v) {
      missing.push(key)
    } else {
      values[key] = v
    }
  }

  return { values, resource: search.get('resource'), missing }
}

function buildCancelUrl(redirectUri: string, state: string): string {
  const sep = redirectUri.includes('?') ? '&' : '?'
  return `${redirectUri}${sep}error=access_denied&state=${encodeURIComponent(state)}`
}

export default function OAuthAuthorizePage() {
  const [searchParams] = useSearchParams()
  const { values, resource, missing } = readParams(searchParams)

  const clientQuery = useQuery({
    queryKey: ['oauth-client', values.client_id],
    queryFn: () => fetchOAuthClient(values.client_id),
    enabled: missing.length === 0 && !!values.client_id,
    retry: false,
  })

  const meQuery = useMe()
  const vaultsQuery = useVaults()

  const [vaultChoice, setVaultChoice] = useState<string>('vault:*')
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  useEffect(() => {
    if (vaultChoice === 'vault:*' || !vaultsQuery.data) return
    if (vaultChoice.startsWith('vault:')) {
      const id = vaultChoice.slice('vault:'.length)
      const stillExists =
        id === '*' || vaultsQuery.data.some((v) => String(v.id) === id)
      if (!stillExists) setVaultChoice('vault:*')
    }
  }, [vaultsQuery.data, vaultChoice])

  if (missing.length > 0) {
    return (
      <AuthShell>
        <AuthPanel className="flex flex-col gap-3">
          <h1 className={heading}>
            Invalid authorization request
          </h1>
          <div
            role="alert"
            className={destructiveAlert}
          >
            <p className="font-medium text-foreground">Missing required OAuth parameters:</p>
            <ul className="mt-2 list-inside list-disc text-muted-foreground">
              {missing.map((m) => (
                <li key={m}>
                  <code>{m}</code>
                </li>
              ))}
            </ul>
          </div>
          <p className="text-sm text-muted-foreground">
            This page should be opened via an OAuth client redirect, not directly.
          </p>
        </AuthPanel>
      </AuthShell>
    )
  }

  if (clientQuery.isError) {
    return (
      <AuthShell>
        <AuthPanel className="flex flex-col gap-3">
          <h1 className={heading}>
            Unknown OAuth client
          </h1>
          <div
            role="alert"
            className={destructiveAlert}
          >
            <p className="text-muted-foreground">
              The client requesting access is not registered with Engram.
            </p>
          </div>
        </AuthPanel>
      </AuthShell>
    )
  }

  const handleApprove = async () => {
    setSubmitting(true)
    setSubmitError(null)

    const body: OAuthConsentParams = {
      client_id: values.client_id,
      redirect_uri: values.redirect_uri,
      response_type: values.response_type,
      code_challenge: values.code_challenge,
      code_challenge_method: values.code_challenge_method,
      state: values.state,
      scope: values.scope,
      vault_choice: vaultChoice,
    }
    if (resource) body.resource = resource

    try {
      const { redirect_uri } = await postOAuthConsent(body)
      window.location.assign(redirect_uri)
    } catch (e: unknown) {
      // LimitExceededError is already surfaced by UpgradeDialogProvider
      // (it's a 402 — the dialog opens and offers Disconnect / Upgrade).
      // Don't double-render its raw message as an inline error.
      if (e instanceof Error && e.name === 'LimitExceededError') {
        setSubmitting(false)
        return
      }
      const message = e instanceof Error ? e.message : 'Authorization failed'
      setSubmitError(message)
      setSubmitting(false)
    }
  }

  const handleCancel = () => {
    window.location.assign(buildCancelUrl(values.redirect_uri, values.state))
  }

  const clientName = clientQuery.data?.client_name ?? 'this app'
  const isLoadingShell =
    clientQuery.isLoading || vaultsQuery.isLoading || meQuery.isLoading

  return (
    <AuthShell>
      <AuthPanel className="flex flex-col gap-4">
        <header className="flex flex-col gap-1">
          <h1 className={heading}>
            Authorize <span className="text-primary">{clientName}</span>
          </h1>
          <p className="text-sm text-muted-foreground">
            This app is requesting access to your Engram.
            {meQuery.data ? ` Signed in as ${meQuery.data.email}.` : ''}
          </p>
        </header>

        {isLoadingShell ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : (
          <>
            <fieldset className="flex flex-col gap-2">
              <legend className="mb-1 text-sm font-medium text-foreground">
                Which vault?
              </legend>
              {vaultsQuery.data?.map((v) => {
                const value = `vault:${v.id}`
                const active = vaultChoice === value
                return (
                  <label
                    key={v.id}
                    className={selectableRow(active)}
                  >
                    <input
                      type="radio"
                      name="vault_choice"
                      value={value}
                      checked={active}
                      onChange={() => setVaultChoice(value)}
                      className="accent-primary"
                    />
                    <span className="text-sm font-medium text-foreground">{v.name}</span>
                  </label>
                )
              })}
              <label
                className={selectableRow(vaultChoice === 'vault:*')}
              >
                <input
                  type="radio"
                  name="vault_choice"
                  value="vault:*"
                  checked={vaultChoice === 'vault:*'}
                  onChange={() => setVaultChoice('vault:*')}
                  className="accent-primary"
                />
                <span className="text-sm font-medium text-foreground">All vaults</span>
              </label>
            </fieldset>

            {submitError && (
              <p
                role="alert"
                className={cn(destructiveAlert, 'p-3 text-foreground')}
              >
                {submitError}
              </p>
            )}

            <div className="flex gap-3">
              <Button type="button" onClick={handleApprove} disabled={submitting} className="flex-1">
                {submitting ? 'Approving…' : 'Approve'}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={handleCancel}
                disabled={submitting}
                className="flex-1"
              >
                Cancel
              </Button>
            </div>
          </>
        )}
      </AuthPanel>
    </AuthShell>
  )
}
