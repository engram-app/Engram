import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router'
import { useQuery } from '@tanstack/react-query'
import {
  fetchOAuthClient,
  postOAuthConsent,
  type OAuthConsentParams,
} from '../api/oauth'
import { useVaults, useMe } from '../api/queries'

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
      <main style={pageStyle}>
        <h1>Invalid authorization request</h1>
        <p>Missing required OAuth parameters:</p>
        <ul>
          {missing.map((m) => (
            <li key={m}>
              <code>{m}</code>
            </li>
          ))}
        </ul>
        <p>This page should be opened via an OAuth client redirect, not directly.</p>
      </main>
    )
  }

  if (clientQuery.isError) {
    return (
      <main style={pageStyle}>
        <h1>Unknown OAuth client</h1>
        <p>The client requesting access is not registered with Engram.</p>
      </main>
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
      const message = e instanceof Error ? e.message : 'Authorization failed'
      setSubmitError(message)
      setSubmitting(false)
    }
  }

  const handleCancel = () => {
    window.location.assign(buildCancelUrl(values.redirect_uri, values.state))
  }

  const clientName = clientQuery.data?.client_name ?? 'this app'
  const isLoadingShell = clientQuery.isLoading || vaultsQuery.isLoading || meQuery.isLoading

  return (
    <main style={pageStyle}>
      <h1>
        Authorize <strong>{clientName}</strong> to access your Engram
      </h1>
      {meQuery.data && <p>Signed in as {meQuery.data.email}.</p>}

      {isLoadingShell ? (
        <p>Loading…</p>
      ) : (
        <>
          <fieldset style={fieldsetStyle}>
            <legend>Which vault?</legend>
            {vaultsQuery.data?.map((v) => (
              <label key={v.id} style={labelStyle}>
                <input
                  type="radio"
                  name="vault_choice"
                  value={`vault:${v.id}`}
                  checked={vaultChoice === `vault:${v.id}`}
                  onChange={() => setVaultChoice(`vault:${v.id}`)}
                />{' '}
                {v.name}
              </label>
            ))}
            <label style={labelStyle}>
              <input
                type="radio"
                name="vault_choice"
                value="vault:*"
                checked={vaultChoice === 'vault:*'}
                onChange={() => setVaultChoice('vault:*')}
              />{' '}
              All vaults
            </label>
          </fieldset>

          {submitError && (
            <p style={{ color: 'red' }} role="alert">
              {submitError}
            </p>
          )}

          <section style={{ display: 'flex', gap: '0.75rem', marginTop: '1rem' }}>
            <button
              type="button"
              onClick={handleApprove}
              disabled={submitting}
              style={primaryBtn}
            >
              {submitting ? 'Approving…' : 'Approve'}
            </button>
            <button
              type="button"
              onClick={handleCancel}
              disabled={submitting}
              style={secondaryBtn}
            >
              Cancel
            </button>
          </section>
        </>
      )}
    </main>
  )
}

const pageStyle: React.CSSProperties = {
  maxWidth: 480,
  margin: '4rem auto',
  padding: '1rem',
  fontFamily: 'system-ui, sans-serif',
}

const fieldsetStyle: React.CSSProperties = {
  border: '1px solid #ccc',
  padding: '1rem',
  margin: '1rem 0',
}

const labelStyle: React.CSSProperties = {
  display: 'block',
  padding: '0.25rem 0',
  cursor: 'pointer',
}

const primaryBtn: React.CSSProperties = {
  padding: '0.5rem 1rem',
  fontSize: '1rem',
  cursor: 'pointer',
}

const secondaryBtn: React.CSSProperties = {
  padding: '0.5rem 1rem',
  fontSize: '1rem',
  cursor: 'pointer',
  background: 'transparent',
  border: '1px solid #ccc',
}
