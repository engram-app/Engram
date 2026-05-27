import { ClerkProvider, useAuth, useClerk } from '@clerk/clerk-react'
import { dark } from '@clerk/themes'
import { useCallback, useEffect, useMemo } from 'react'
import { AuthContext, type AuthAdapter } from './auth-context'
import { rememberSignupUser } from './signup-rejection'
import { setTokenGetter } from '../api/client'
import { config } from '../config'
import { ROUTES } from '../routes'
import { useTheme } from '../theme/theme-provider'

const clerkPubKey = config.clerkPublishableKey

// Map Clerk onto Engram's CSS design tokens. The Clerk React components render
// in-DOM (not an iframe), so these var() references resolve against the document.
// The dark baseTheme (applied reactively below) is what flips Clerk's own
// surface/brand-glyph handling — colorPrimary etc. then re-skin it to brand.
const clerkVariables = {
  colorPrimary: 'var(--primary)',
  colorText: 'var(--foreground)',
  colorTextSecondary: 'var(--muted-foreground)',
  colorBackground: 'var(--card)',
  colorInputBackground: 'var(--background)',
  colorInputText: 'var(--foreground)',
  colorNeutral: 'var(--foreground)',
  borderRadius: 'var(--radius)',
  fontFamily: "'Inter Variable', system-ui, sans-serif",
}

const clerkElements = {
  cardBox: 'border border-border shadow-2xl shadow-primary/10',
  card: 'bg-card',
  footer: 'bg-transparent',
}

function ClerkAdapterInner({ children }: { children: React.ReactNode }) {
  const { isLoaded, isSignedIn, getToken } = useAuth()
  const clerk = useClerk()

  const tokenGetter = useCallback(() => getToken(), [getToken])

  useEffect(() => {
    setTokenGetter(tokenGetter)
  }, [tokenGetter])

  // Remember the Clerk user id while we still have it. If the multi-account
  // block deletes this user moments later, the sign-in bounce can look up why.
  const clerkUserId = clerk.user?.id
  useEffect(() => {
    if (clerkUserId) rememberSignupUser(clerkUserId)
  }, [clerkUserId])

  const email = clerk.user?.primaryEmailAddress?.emailAddress
  const adapter: AuthAdapter = useMemo(
    () => ({
      isLoaded,
      isSignedIn: isSignedIn ?? false,
      user: isSignedIn && email ? { email } : null,
      getToken: tokenGetter,
      logout: async () => { await clerk.signOut() },
      hasBuiltInUI: true,
    }),
    [isLoaded, isSignedIn, clerk, email, tokenGetter],
  )

  return <AuthContext.Provider value={adapter}>{children}</AuthContext.Provider>
}

export default function ClerkAuthProvider({ children }: { children: React.ReactNode }) {
  const { resolved } = useTheme()

  const appearance = useMemo(
    () => ({
      baseTheme: resolved === 'dark' ? dark : undefined,
      variables: clerkVariables,
      elements: clerkElements,
    }),
    [resolved],
  )

  if (!clerkPubKey) {
    throw new Error('CLERK_PUBLISHABLE_KEY is required when AUTH_PROVIDER=clerk')
  }

  return (
    <ClerkProvider
      publishableKey={clerkPubKey}
      appearance={appearance}
      signInUrl={ROUTES.SIGN_IN}
      signUpUrl={ROUTES.SIGN_UP}
      afterSignOutUrl={ROUTES.SIGN_IN}
    >
      <ClerkAdapterInner>{children}</ClerkAdapterInner>
    </ClerkProvider>
  )
}
