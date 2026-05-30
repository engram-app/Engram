import { useEffect, useState } from 'react'
import { config } from '../config'

export interface Bootstrap {
  bootstrap_pending: boolean
  registration_mode: 'open' | 'invite_only' | 'closed'
}

// Discriminates "still fetching" from "loaded but no data". A `null` result
// means we definitively know there is no self-host bootstrap (404 / Clerk /
// network error → fall back to defaults). `undefined` means "don't render
// mode-dependent UI yet" — UI shows a skeleton/placeholder until this
// resolves, avoiding the default→correct flash on every navigation.
export type BootstrapState = Bootstrap | null | undefined

// Seed from Phoenix's SSR-injected runtime config when available. In prod
// this means useBootstrap() is synchronous on first paint — no fetch, no
// flash. In dev (Vite serves index.html, no injection) `config.bootstrap`
// is undefined and we fall back to fetching the public endpoint.
let cached: Bootstrap | null | undefined = config.bootstrap
let inflight: Promise<Bootstrap | null> | null = null

function fetchBootstrap(): Promise<Bootstrap | null> {
  if (inflight) return inflight
  inflight = fetch('/api/auth/bootstrap')
    .then((r) => (r.ok ? r.json() : null))
    .catch(() => null)
    .then((b: Bootstrap | null) => {
      cached = b
      return b
    })
  return inflight
}

export function useBootstrap(): BootstrapState {
  const [state, setState] = useState<BootstrapState>(cached)

  useEffect(() => {
    if (cached !== undefined) return
    let cancelled = false
    fetchBootstrap().then((b) => {
      if (!cancelled) setState(b)
    })
    return () => {
      cancelled = true
    }
  }, [])

  return state
}
