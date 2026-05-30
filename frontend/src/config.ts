export interface EngramConfig {
  authProvider: 'local' | 'clerk'
  clerkPublishableKey: string
  billingEnabled: boolean
  // Self-host SSR-injected bootstrap state. `null` under Clerk; `undefined`
  // when the config script didn't ship one (Vite dev, older Phoenix build),
  // in which case useBootstrap() falls back to fetching /api/auth/bootstrap.
  bootstrap?: {
    bootstrap_pending: boolean
    registration_mode: 'open' | 'invite_only' | 'closed'
  } | null
}

const VALID_PROVIDERS = ['local', 'clerk'] as const

export function loadConfig(): EngramConfig {
  const injected = (window as unknown as { __ENGRAM_CONFIG__?: Record<string, unknown> })
    .__ENGRAM_CONFIG__

  if (injected && VALID_PROVIDERS.includes(injected.authProvider as typeof VALID_PROVIDERS[number])) {
    return {
      authProvider: injected.authProvider as 'local' | 'clerk',
      clerkPublishableKey: (injected.clerkPublishableKey as string) ?? '',
      billingEnabled: injected.billingEnabled === true,
      bootstrap: injected.bootstrap as EngramConfig['bootstrap'],
    }
  }

  // Vite dev server fallback — not served by Phoenix
  if (import.meta.env.PROD && !injected) {
    console.error(
      '[engram] window.__ENGRAM_CONFIG__ not found. ' +
      'Server may have failed to inject runtime config. Falling back to local auth.',
    )
  }

  return {
    authProvider: (import.meta.env.VITE_AUTH_PROVIDER as 'local' | 'clerk') ?? 'local',
    clerkPublishableKey: import.meta.env.VITE_CLERK_PUBLISHABLE_KEY ?? '',
    billingEnabled: import.meta.env.VITE_BILLING_ENABLED === 'true',
  }
}

export const config = loadConfig()
