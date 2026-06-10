export interface EngramConfig {
  authProvider: 'local' | 'clerk'
  clerkPublishableKey: string
  billingEnabled: boolean
  // Mirrors Clerk Dashboard "Waitlist" sign-up mode. UI flips "Sign up"
  // CTAs to /waitlist and passes waitlistUrl to <SignIn />. The dashboard
  // flag is the actual enforcement; this is presentational only.
  clerkWaitlistMode: boolean
  // Runtime API base URL. Empty string = same-origin (selfhost, Phoenix
  // serves both API and SPA). A full URL = saas (CF Pages serves SPA,
  // backend hosted elsewhere — e.g. https://api.engram.page).
  apiBase: string
  // Runtime WebSocket base URL. Empty string = same-origin (selfhost).
  // A full wss:// URL points Phoenix Socket at the cross-origin backend.
  wsBase: string
  // Self-host SSR-injected bootstrap state. `null` under Clerk; `undefined`
  // when the config didn't ship one (CF Pages serves static config.json
  // without a bootstrap block; Vite dev; older Phoenix build), in which
  // case useBootstrap() falls back to fetching /api/auth/bootstrap.
  bootstrap?: {
    bootstrap_pending: boolean
    registration_mode: 'open' | 'invite_only' | 'closed'
  } | null
}

const VALID_PROVIDERS = ['local', 'clerk'] as const

function normalize(raw: Record<string, unknown>): EngramConfig {
  const provider = VALID_PROVIDERS.includes(raw.authProvider as typeof VALID_PROVIDERS[number])
    ? (raw.authProvider as 'local' | 'clerk')
    : 'local'

  return {
    authProvider: provider,
    clerkPublishableKey: typeof raw.clerkPublishableKey === 'string' ? raw.clerkPublishableKey : '',
    billingEnabled: raw.billingEnabled === true,
    clerkWaitlistMode: raw.clerkWaitlistMode === true,
    apiBase: typeof raw.apiBase === 'string' ? raw.apiBase : '',
    wsBase: typeof raw.wsBase === 'string' ? raw.wsBase : '',
    bootstrap: raw.bootstrap as EngramConfig['bootstrap'],
  }
}

function defaultConfig(): EngramConfig {
  return {
    authProvider: (import.meta.env.VITE_AUTH_PROVIDER as 'local' | 'clerk') ?? 'local',
    clerkPublishableKey: import.meta.env.VITE_CLERK_PUBLISHABLE_KEY ?? '',
    billingEnabled: import.meta.env.VITE_BILLING_ENABLED === 'true',
    clerkWaitlistMode: import.meta.env.VITE_CLERK_WAITLIST_MODE === 'true',
    apiBase: import.meta.env.VITE_API_BASE ?? '',
    wsBase: import.meta.env.VITE_WS_BASE ?? '',
  }
}

// Selfhost no-op contract: when Phoenix SSR-injects __ENGRAM_CONFIG__ this
// resolves synchronously on first microtask (no fetch). Only the CF Pages
// path (no injection) hits /config.json. Falls through to env-driven
// defaults if both fail — emit a single console error in prod so a missing
// /config.json deploy is loud rather than silently broken.
export async function loadConfig(): Promise<EngramConfig> {
  const injected = (window as unknown as { __ENGRAM_CONFIG__?: Record<string, unknown> })
    .__ENGRAM_CONFIG__

  if (injected) return normalize(injected)

  try {
    const res = await fetch('/config.json', { cache: 'no-cache' })
    if (res.ok) {
      const raw = await res.json()
      return normalize(raw)
    }
  } catch {
    // Fall through to defaults below.
  }

  if (import.meta.env.PROD) {
    console.error(
      '[engram] no window.__ENGRAM_CONFIG__ and /config.json unreachable. Falling back to defaults.',
    )
  }

  return defaultConfig()
}

// Module-level promise — kicked off once at import time. `BootstrapGate`
// awaits this via React 19's `use()` so the SPA mounts only after config
// resolves. Re-imports get the same promise (module cache), so the fetch
// fires at most once per page load.
export const configPromise = loadConfig()
