import { ClerkProvider, useAuth, useClerk } from '@clerk/clerk-react'
import { useCallback, useEffect, useMemo } from 'react'
import { AuthContext, type AuthAdapter } from './auth-context'
import { setTokenGetter } from '../api/client'
import { config } from '../config'

const clerkPubKey = config.clerkPublishableKey

function ClerkAdapterInner({ children }: { children: React.ReactNode }) {
  const { isLoaded, isSignedIn, getToken } = useAuth()
  const clerk = useClerk()

  const tokenGetter = useCallback(() => getToken(), [getToken])

  useEffect(() => {
    setTokenGetter(tokenGetter)
  }, [tokenGetter])

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
  if (!clerkPubKey) {
    throw new Error('CLERK_PUBLISHABLE_KEY is required when AUTH_PROVIDER=clerk')
  }

  return (
    <ClerkProvider
      publishableKey={clerkPubKey}
      signInUrl="/sign-in"
      signUpUrl="/sign-up"
      afterSignOutUrl="/sign-in"
    >
      <ClerkAdapterInner>{children}</ClerkAdapterInner>
    </ClerkProvider>
  )
}
